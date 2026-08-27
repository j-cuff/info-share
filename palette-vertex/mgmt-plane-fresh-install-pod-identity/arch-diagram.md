# Architecture — Palette VerteX mgmt-plane with EKS Pod Identity

Two Mermaid diagrams: mgmt-plane at rest, and the workload-cluster provisioning
path. Both render natively in GitHub.

## Diagram 1 — Mgmt cluster components and their AWS auth path

```mermaid
flowchart TB
    subgraph AWS["AWS APIs"]
        direction LR
        STS["STS<br/>sts:AssumeRoleForPodIdentity"]
        EC2["EC2<br/>describe VPC/subnets/SGs/keypairs"]
        EKS["EKS<br/>describe clusters/nodegroups/addons"]
        IAM["IAM<br/>validate roles/policies"]
        KMS["KMS<br/>describe keys"]
        EKS_AUTH["EKS Auth<br/>Pod Identity Associations<br/>(create/delete/list)"]
        ELB["ELB / ELBv2<br/>NLB / ALB CRUD"]
        EBS["EBS<br/>CreateVolume / Attach"]
        ECR["ECR<br/>image pulls"]
    end

    subgraph MGMT["EKS mgmt cluster (self-managed by customer)"]
        AGENT["eks-pod-identity-agent<br/>DaemonSet, kube-system<br/>(injects env vars into pods)"]

        subgraph HUB_NS["namespace: hubble-system"]
            HUB["spectro-hubble<br/>SA: spectro-hubble<br/>→ SpectroCloudHubbleRole"]
        end

        subgraph ID_NS["namespace: palette-identity"]
            ID["palette-identity<br/>SA: palette-identity<br/>→ SpectroCloudIdentityRole"]
        end

        subgraph CAPA_NS["namespace: capa-system"]
            CAPA["capa-controller-manager<br/>SA: capa-controller-manager<br/>→ SpectroCloudPaletteRole"]
        end

        subgraph KUBE_NS["namespace: kube-system (addons)"]
            LBC["aws-load-balancer-controller<br/>SA: aws-load-balancer-controller<br/>→ LBC role"]
            EBSCTL["ebs-csi-controller<br/>SA: ebs-csi-controller-sa<br/>→ EBS CSI role"]
            VPCCNI["aws-node / VPC CNI<br/>SA: aws-node<br/>→ VPC CNI role"]
        end

        subgraph CHART_NS["namespace: default (spectro-mgmt-plane release)"]
            OTHER["specman / configserver / imageswap / mongo / auth<br/>(NO Pod Identity — ECR creds baked in chart values;<br/>mongo/auth make no AWS calls)"]
        end
    end

    HUB -.->|Pod Identity token exchange| AGENT
    ID -.->|Pod Identity token exchange| AGENT
    CAPA -.->|Pod Identity token exchange| AGENT
    LBC -.->|Pod Identity token exchange| AGENT
    EBSCTL -.->|Pod Identity token exchange| AGENT
    VPCCNI -.->|Pod Identity token exchange| AGENT

    AGENT ==>|"AssumeRoleForPodIdentity<br/>(one per SA/role pair)"| STS

    HUB ==>|Hubble role creds| EC2 & EKS & IAM & KMS
    ID ==>|Identity role creds| EKS_AUTH
    ID -.->|PassRole for provisioning| CAPA
    CAPA ==>|Palette role creds| EC2 & EKS & IAM & ELB
    LBC ==>|LBC role creds| ELB
    EBSCTL ==>|EBS role creds| EBS
    VPCCNI ==>|VPC CNI role creds| EC2

    OTHER -.->|dockerconfigjson secret<br/>from chart values.config.ociImageRegistry| ECR
```

**Legend:**

- `-.->` = env-var injection or credential-material path
- `==>` = actual AWS API call
- Each mgmt-plane pod that needs AWS talks first to the local Pod Identity
  agent DaemonSet; the agent handles the STS token exchange; the pod gets
  temp creds and uses them for the real AWS call.
- ECR access from chart components (`specman` / `configserver` / `imageswap`)
  does NOT go through Pod Identity — the chart's
  `config.ociImageRegistry.username/password` values bake registry creds into
  a Kubernetes Secret at install time. Pod Identity for ECR is possible but
  not the pattern this chart uses.

## Diagram 2 — Workload cluster provisioning + phone-home

```mermaid
flowchart TB
    subgraph AWS["AWS APIs"]
        STS2["STS<br/>AssumeRoleWithWebIdentity"]
        ECR2["ECR"]
        EBS2["EBS<br/>ec2:*Volume"]
        EFS2["EFS<br/>elasticfilesystem"]
    end

    subgraph MGMT2["Mgmt cluster (from Diagram 1)"]
        CAPA2["capa-controller-manager<br/>SA=capa-controller-manager"]
    end

    subgraph WL["Workload EKS cluster (Palette-managed)"]
        direction TB
        WL_WARN["⚠ RULE 5 caveat<br/>eks-pod-identity-agent is RECONCILED AWAY<br/>by Palette CMA within ~4 min unless declared<br/>in the cluster profile. Use IRSA (pod-identity-webhook<br/>pre-installed) for anything needing AWS creds."]
        subgraph WL_KS["namespace: kube-system"]
            WL_CMA["cluster-management-agent<br/>(CMA)"]
            WL_JET["jet<br/>(control-plane agent)"]
            WL_EBSCTL["ebs-csi-controller<br/>SA annotated with<br/>eks.amazonaws.com/role-arn<br/>(IRSA — reconcile-proof)"]
        end
        subgraph WL_APP["app namespaces (customer)"]
            WL_KPACK["kpack (if deployed)<br/>SA annotated with IRSA role"]
        end
    end

    CAPA2 ==>|"CreateCluster / CreateVpc /<br/>CreateRole / RegisterCluster"| WL

    WL_CMA -->|HTTPS to mgmt-plane<br/>rootDomain/v1/*| MGMT2
    WL_JET -->|HTTPS to mgmt-plane<br/>rootDomain/v1/auth/*| MGMT2

    WL_EBSCTL -.->|"AWS_ROLE_ARN +<br/>AWS_WEB_IDENTITY_TOKEN_FILE<br/>(webhook injects)"| STS2
    WL_EBSCTL ==>|CreateVolume etc| EBS2

    WL_KPACK -.->|IRSA token exchange| STS2
    WL_KPACK ==>|GetAuthToken / PutImage| ECR2
```

**Why the two workload-cluster diagrams differ from mgmt cluster:**

| Aspect | Mgmt cluster | Workload cluster |
|---|---|---|
| Ownership | Self-managed (you own kubelet, addons, everything) | Palette-managed (CMA reconciles state) |
| Pod Identity addon | Present, stable | Removed by Palette within ~4 min unless in profile |
| Standard AWS-auth pattern | Pod Identity Associations | IRSA on SA annotations (survives reconciliation) |
| Node role IAM policies | Whatever you attach stays | `spectro__ownerUid`-tagged; managed-policy attachments reconciled off |

Recommendation: use Pod Identity on the mgmt cluster (this diagram),
and use IRSA on workload clusters — annotate the ServiceAccount with
`eks.amazonaws.com/role-arn` and give the role a trust policy for
`sts:AssumeRoleWithWebIdentity` from the workload cluster's OIDC provider.
IRSA survives Palette's cluster-profile reconciler because it lives on
the SA annotation, which the reconciler doesn't touch. Only skip this if
you explicitly declare the Pod Identity Agent addon in the workload
cluster profile so it doesn't get reconciled away.
