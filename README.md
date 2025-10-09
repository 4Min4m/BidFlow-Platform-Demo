# BidFlow: Self-Service Bidding Platform Demo

BidFlow is a practical demonstration of an Internal Developer Platform (IDP) designed for self-service deployment and management of a real-time auction bidding microservice. Drawing inspiration from dynamic auction environments like Catawiki, it focuses on enabling developers to deploy, scale, and observe applications with minimal friction, while abstracting Kubernetes complexities. The core microservice processes JSON bids—validating amounts, storing them in Redis with configurable TTLs for expiration, and exposing structured metrics and logs for analysis. This setup highlights platform engineering principles: Automating repetitive tasks, promoting collaboration across teams, and ensuring reliability through measurable outcomes like fast deployments and low error rates.

The project emphasizes polyglot support (e.g., Ruby or Go runtimes) and extensibility, making it adaptable for production-like scenarios where bids must handle bursty traffic without downtime.

## How I Created It
I developed BidFlow over a focused weekend as preparation for a senior platform engineer role, starting with a simple Ruby Sinatra prototype to simulate auction bid flows (inspired by real-world transcripts on high-traffic GC tuning). From there, I layered in infrastructure using Terraform for provisioning a GKE Autopilot cluster, GitHub Actions for an end-to-end CI/CD pipeline (build, test, and Helm deploy), and Helm for templated, reusable manifests. The iterative process mirrored a real team cycle: Prototype the app locally with Docker, containerize for slim images (~150MB runtime), then automate the pipeline to enforce immutability (SHA-tagged deploys).

To build collaboration skills, I simulated cross-team feedback by role-playing with AI as "teammates" (a developer, platform engineer, and product owner). Their hypothetical questions drove refinements—like adding language-specific env vars or A/B flags—turning solo coding into a narrative of listening, prototyping, and validating changes. Finally, I polished with diagrams, badges, and a log parser script for quick anomaly prototyping, ensuring the whole stack deploys in under 2 minutes. This hands-on approach refreshed my knowledge of cloud-native patterns while creating a tangible artifact to discuss in interviews.

## Key Features
BidFlow prioritizes developer speed and system resilience, with features that reduce toil and enable experimentation in a controlled way.

- **Self-Service Deploys**: A customizable Helm chart lets teams deploy via simple overrides in `values.yaml` (e.g., `language: ruby` for GC tuning or `go` for GOGC=100). The GitOps pipeline in Actions handles everything—Docker build/test/push to GCR, then rolling Helm upgrades with immutable SHA tags—ensuring traceability and zero-downtime updates.

- **Scaling & Reliability**: Horizontal Pod Autoscaler (HPA) dynamically adjusts replicas (1-5) based on CPU utilization (>50% threshold), perfect for auction spikes. Liveness and readiness probes (/live and /ready endpoints) prevent unhealthy pods from receiving traffic, while lazy Redis connections allow graceful degradation (e.g., log bids without storage during outages).

- **A/B Experimentation**: Environment flags enable safe testing of features like Redis TTLs (30s for Variant A vs. 120s for B), with logs tagged by variant for easy analysis. This supports product-driven iterations without code redeploys, promoting data-informed decisions on bid expiration impacts.

- **Observability & Anomaly Detection**: The app exposes a /metrics endpoint with Prometheus annotations for scraping, alongside structured JSON logs (e.g., `{event: 'bid_rejected', reason: 'duplicate'}`). A Python script (`scripts/parsing/log_parser.py`) prototypes local anomaly detection using Z-scores on bid amounts, serving as a foundation for ELK pipelines that alert on spikes (e.g., fraud patterns).

- **Data Resilience**: A 1Gi PersistentVolumeClaim (PVC) backs Redis for stateful storage, with a CronJob performing RDB backups to GCS every 6 hours (using gsutil for cloud sync, secured via Workload Identity).

These elements collectively cut deployment time to seconds, lower MTTR through proactive probes, and foster maintainable code with modular validation and error handling.

## Teammate Iterations
Collaboration is core to platform success, so I incorporated simulated feedback from AI "teammates" to refine features, practicing empathy and iteration in a hypothetical team setting.

- **Dev Teammate (Runtime Customization)**: Questioning how to handle Ruby vs. Go without fragmented charts led to conditional env vars in the Deployment template (e.g., RUBY_GC_HEAP_GROWTH_FACTOR for Ruby or GOGC for Go). This creates a single, extensible chart—reducing cognitive load and enabling polyglot self-service while maintaining consistency.

- **Platform Teammate (Observability Stack)**: Guidance on ELK for bid errors and anomaly tips inspired structured logs with reason codes and the log_parser.py script for Z-score validation. It also added Prometheus-ready annotations, ensuring logs/metrics flow into tools like Fluent Bit → Elasticsearch for alerting on rejection rates—balancing observability with minimal ops overhead.

- **Product Teammate (Experiment Priorities)**: Focus on low-latency A/B for TTLs resulted in env-driven variants in app.rb, with logs tagged for variant-specific analysis. This decouples experiments from core logic, allowing quick tests of UX impacts (e.g., longer TTLs for perceived reliability) while enforcing fairness through consistent labeling.

These interactions (detailed in `docs/teammate-simulations.md`) underscore ownership: Start with pain points, prototype solutions, and measure (e.g., A/B latency diffs via /metrics).

## Tech Stack
The stack is chosen for reliability, cost-efficiency, and ease of extension, leveraging managed services where possible to minimize toil.

- **Cloud & Orchestration**: Google Kubernetes Engine (GKE) Autopilot for auto-scaling nodes (~$0.10/hr idle, scales to zero); Kubernetes for core primitives (pods, services); Helm for templated, versioned manifests that abstract YAML complexity.
- **IaC & CI/CD**: Terraform for declarative infra (immutable GKE + PVC provisioning); GitHub Actions for the pipeline (Docker multi-stage builds, unit tests via curl health checks, and Helm deploys—mocking ArgoCD for GitOps).
- **App Runtime**: Ruby 3.2 with Sinatra for the lightweight API (lazy Redis for fault-tolerant storage); Redis for fast in-memory bids (TTL for expiration); Docker for containerization (builder stage for gems, slim runtime for efficiency).
- **Observability**: Prometheus annotations and /metrics for scraping; JSON-structured logs compatible with ELK (Elasticsearch for storage, Kibana for viz); Python stats (mean/stdev) in log_parser.py for prototype anomaly detection.
- **Extras**: HPA for horizontal scaling; CronJob for scheduled backups; PVC for persistence.

This combination ensures "simple yet scalable"—e.g., Autopilot handles node FinOps, while Helm empowers devs without deep K8s knowledge.

## Future Enhancements
To mature into a full IDP:
- **Redis & Storage**: Deploy a Redis StatefulSet mounting the PVC, with shared Memorystore for multi-tenant auctions.
- **Advanced Observability**: Integrate kube-prometheus-stack for full scraping/alerting; ES ML jobs for real-time anomaly detection on bid fraud; Grafana SLO dashboards (e.g., 99.9% latency).
- **GitOps & Security**: Migrate to ArgoCD for pull-based deploys; Add NetworkPolicies/mTLS for service mesh; Workload Identity for secure GCS access.
- **Chaos & Experiments**: Litmus for fault injection (e.g., Redis outages); Feature flags (LaunchDarkly) for dynamic A/B without redeploys.