## 2. AI Tools Used

| Tool | Purpose | Areas of Assistance |
|---|---|---|
| Claude | Research and Development (R&D) | Exploring and developing Terraform-based Infrastructure as Code configurations |
| ChatGPT | Technical assistance and implementation review | Terraform troubleshooting, Kubernetes and Helm configuration, Ray Serve integration, CI/CD automation, and documentation |

These tools were used to support engineering research and development. Their outputs were reviewed and adapted to the project's requirements rather than treated as authoritative or production-ready solutions.

## 3. Areas of AI Assistance

### Infrastructure as Code (IaC) — Claude

Claude was used during the R&D phase to explore and develop Terraform configurations for provisioning the cloud infrastructure on ArvanCloud.

The assistance focused on:

- Researching the available Terraform provider resources and configuration options.
- Developing and refining Terraform configurations for virtual machines and private networking.
- Exploring public IP attachment and infrastructure resource dependencies.
- Developing automation workflows for SSH connectivity, server initialization, kernel tuning, and Kubespray installation.
- Investigating Terraform errors and refining the infrastructure provisioning approach.

The resulting configurations were adapted to the project's infrastructure requirements, available cloud resources, and deployment workflow. AI-generated suggestions were considered development inputs and required validation against the actual provider schema and environment.

### Application, Kubernetes, and CI/CD — ChatGPT

ChatGPT was used to support implementation review, troubleshooting, and documentation across the remaining project components, including:

- Reviewing the Python inference application using FastAPI, Ray Serve, and vLLM.
- Reviewing Kubernetes and Helm configuration for the RayService, NodePort Service, and VictoriaMetrics Pod scraping.
- Troubleshooting deployment configuration and resource allocation.
- Reviewing GitHub Actions CI/CD workflow design, image publishing, and SSH-based deployment.
- Preparing project documentation and deployment instructions.

The project author remained responsible for integrating the components, making engineering decisions, and verifying the behavior of the resulting system.