# The Infrastructure Behind a Production-Style Fintech Project

How PayFlow is deployed on Kubernetes and EKS, how Terraform provisions identical environments, how the CI/CD pipeline moves code from commit to running pod, and how the observability stack tells you whether money is moving or silently frozen.

This is part three of a series on building and operating PayFlow. Part one traced a $50 transfer across six microservices. Part two explained the four concepts — atomicity, idempotency, auditability, least privilege — that stop fintech systems from breaking in production. This article covers the infrastructure that holds all of that together.

---

Let me tell you about a scenario that trips up almost every engineer the first time they deploy to a real cluster.

The GitHub Actions pipeline goes green, the Docker image is built, and `kubectl rollout status` says the deployment succeeded. You run `kubectl get pods` and every pod shows `Running 1/1`. You close your laptop. Everything looks healthy.

Then a user calls. Their $200 transfer never arrived. The money left their account, it did not arrive in the recipient's, and it has been sitting frozen in a `PENDING` state in the database for the past twenty minutes — and nothing in the cluster gave any indication that anything was wrong.

Here is what actually happened. `Running` means the container started, not that the service inside it is actually processing work. The CronJob that reverses stuck transactions had been failing silently because no one had wired up an alert for it. The infrastructure was up, the money was frozen, and there was no signal anywhere that pointed to the cause.

That scenario is the gap between "I deployed a web app" and "I can operate a system that handles money." The gap is not in the application code — most developers can write Node.js. The gap is in everything underneath: how environments get created reliably, how code gets from a laptop into a running container, how the cluster enforces which services are allowed to talk to which, and how you know in real time whether the system is healthy or quietly losing transactions.

PayFlow is a teaching project built to close that gap, and by the end of this article you will be able to explain every layer of that infrastructure — what it does, why it exists, and exactly what fails when any piece of it is missing.

---

## First: the big picture

Before we go layer by layer, let me give you a sense of what you are actually looking at.

PayFlow runs six services — an API gateway, auth, wallet, transaction processor, notification, and a React frontend — and they communicate over HTTP and a message queue. Their data lives in PostgreSQL, Redis, and RabbitMQ. On a laptop, that whole thing starts with `docker compose up` and you are done. In a cloud environment, each piece runs as a containerised pod inside a Kubernetes cluster on AWS EKS, and that cluster lives inside a private network provisioned by Terraform. Code gets there through a GitHub Actions pipeline, and metrics and logs flow to a monitoring stack so engineers can actually see what is happening without tailing individual pod logs at 2am.

Each of those pieces — Terraform, Kubernetes, CI/CD, observability — could be its own article. We are going to walk through them in the order they matter: first the environment gets built, then code arrives in it, then you watch it run.

---

## Layer 1: Terraform — building the environment before a single container starts

### What Terraform actually is

If you have ever joined a team and heard "we use Terraform for infrastructure," and nodded along without fully knowing what that meant, here is the short version. Terraform is a tool that lets you describe your cloud infrastructure in text files and then create it from those files. Instead of clicking through the AWS console — creating a VPC here, a security group there, hoping you remember every setting the next time you need to recreate it — you write code that says what you want, and Terraform makes it happen.

The real benefit is reproducibility, and it sounds boring until you need it. Anyone with the right credentials can run `terraform apply` and get an environment identical to the one already running in production. No "it worked on my setup," no forgotten manual steps, no senior engineer who is the only one who knows how the network was configured.

One thing worth saying clearly: Terraform is not Ansible, which manages what is installed *inside* servers. Terraform creates the servers and networks themselves. It is also not the same as AWS CloudFormation — they do the same job, but Terraform works across cloud providers and has a cleaner syntax. And it is not Kubernetes. Terraform builds the infrastructure that Kubernetes runs on top of. They are different tools with different jobs, and both are in PayFlow.

### The hub-and-spoke layout

PayFlow's AWS environment follows a pattern called hub-and-spoke, which is one of those enterprise patterns that sounds complicated until you have the analogy for it. Think of a city and its suburbs. The hub VPC (Virtual Private Cloud — AWS's term for a private network you fully control) handles shared connectivity, and the spoke VPC is where the actual application lives — the EKS cluster, its worker nodes, and the private subnets those nodes run in.

> **VPC:** A logically isolated section of AWS's network that you define. Nothing gets in or out unless you explicitly allow it, and every PayFlow resource — cluster, database, cache — lives inside one.

> **Subnet:** A slice of that private network. Private subnets have no direct route to the internet, which is what you want for databases and internal services. Public subnets can reach the internet through a gateway, which is what you need for load balancers.

The databases and caches — PostgreSQL on RDS, Redis on ElastiCache, RabbitMQ on Amazon MQ — live in a third slice called managed services. They are completely separate from the Kubernetes cluster, and only the cluster's worker nodes can reach them, enforced by security groups.

> **Security group:** AWS's firewall for individual resources. The RDS security group in PayFlow only accepts connections from the EKS node security group, which means that even if someone found a gap in the cluster, they still could not connect to the database from outside it.

### What Terraform is actually doing when you run it

This is the part that catches people off guard. Creating "an EKS cluster" sounds like it should take five minutes and a few YAML files. The reality is that it takes around forty minutes the first time, because Terraform is provisioning an entire chain of dependent resources — and skipping any one of them means something breaks silently later.

In order, it provisions the VPC and subnets with route tables and a NAT gateway so private nodes can reach the internet for image pulls, then VPC Flow Logs which write network-level records of every connection attempt to CloudWatch and retain them for a year, then CloudTrail which records every AWS API call to an encrypted S3 bucket for seven years because financial audit requirements are real, then KMS keys to encrypt logs and secrets at rest, then the EKS cluster itself with an OpenID Connect provider, then IRSA roles, and finally Helm releases for the cluster controllers.

Step six — IRSA (IAM Roles for Service Accounts) — is the one that catches most engineers off guard, and it is worth a proper explanation. Normally, when a pod needs to call an AWS API (like reading a database password from Secrets Manager), it needs credentials stored somewhere. IRSA solves this by letting a Kubernetes service account map to an IAM role, so pods get temporary credentials automatically without anyone ever putting an AWS key in a file. Without IRSA, the cluster starts fine and the pods run fine, but anything that needs to actually call AWS fails silently. The load balancer controller cannot create ALBs. External Secrets cannot read from Secrets Manager. Every time you run `kubectl apply` on an Ingress resource, it just disappears without an error message, and you spend two days wondering why nothing is routing. The cluster looks fine. Nothing actually works.

> **Helm:** A package manager for Kubernetes. It bundles complex third-party software like Prometheus or the AWS load balancer controller into "charts" — pre-configured collections of Kubernetes manifests — so you can install them with a single command and a values file instead of hundreds of lines of YAML. Helm is not the same as Kustomize, which we will get to in the next section. Helm installs other people's software; Kustomize manages your own.

All of it together — the network, the audit logs, the encryption, the identity plumbing, the controllers — is what makes the cluster actually function as a production environment rather than just a collection of running containers. And because it is all in Terraform, the answer to "how was this environment built?" is in a version-controlled file that anyone on the team can read, re-run, and change with a pull request.

---

## Layer 2: Kubernetes — running and protecting the application

### The mental model that actually helps

Kubernetes is a system for running and managing containers across a cluster of machines. You tell it what you want — "three replicas of this container, with these environment variables, with access to this secret" — and it makes that happen and keeps it that way, restarting pods when they crash, rescheduling them when a node goes down, and enforcing the rules you have written.

The machines in the cluster are called nodes. The running containers are called pods. The configuration files that describe what should exist are called manifests — YAML files that are declarations of desired state, not instructions.

### How PayFlow organises its manifests

PayFlow uses Kustomize to manage its Kubernetes configuration, and this is worth understanding before anything else because it solves a problem every team eventually runs into. Kustomize lets you write a base set of manifests and then apply environment-specific patches on top of them, without duplicating the files themselves.

To make the distinction concrete: if you have ever maintained a `deployment-prod.yaml` and a `deployment-dev.yaml` that slowly diverged because someone updated one and forgot the other, Kustomize is the fix for that. You write the shared configuration once in the base, and overlays describe only what is different for each environment. Kustomize is not Helm — Helm installs third-party software; Kustomize organises your own.

The base under `k8s/base/` defines everything that is true regardless of where the system is running. There is a dedicated `payflow` namespace — think of it like a folder inside Kubernetes where all PayFlow resources live, isolated from anything else in the cluster. The monitoring stack runs in its own separate `monitoring` namespace, and they do not interfere with each other. The base also includes Deployments for all six services, a ConfigMap with shared environment variables, NetworkPolicies (the cluster's internal firewall, more on that in a moment), PodDisruptionBudgets that tell Kubernetes not to take down more than one replica of any service at a time during maintenance, resource quotas that hard-cap the entire namespace at 4 CPU cores requested and 8GB memory requested so one misbehaving service cannot starve the rest, and HorizontalPodAutoscalers that add replicas automatically when CPU tops 70% or memory tops 80%.

The overlays then patch this base for specific environments. The local overlay adds in-cluster Postgres, Redis, and RabbitMQ because there is no EKS in local development, relaxes probe timing so slower laptops do not fail health checks immediately, and tells Kubernetes to use locally built images. The EKS overlay points to ECR image tags, wires in External Secrets to pull credentials from AWS Secrets Manager, and increases minimum replica counts. Same base, two environments, no copy-pasted files slowly drifting apart.

### The two resources that exist specifically because money is involved

There are two Kubernetes resources in PayFlow that would not exist in a standard web application, and they are both there because of what happens to money when things go wrong.

The first is the database migration Job. Schema changes — adding a column, creating a table — run as a Kubernetes Job at deploy time rather than as a manual psql session that someone might forget. A Job runs a pod to completion and stops; it is not a long-running service. Running migrations as a Job means the schema is always updated before new application pods start, and there is a record in Kubernetes of whether it succeeded.

The second is the transaction timeout CronJob, which runs every minute and queries the database for transactions that have been stuck in `PENDING` or `PROCESSING` status for too long. When it finds any, it reverses them. This is the direct failsafe for the scenario where a pod crashes after debiting a user but before completing the transfer — without it, the money sits locked in limbo indefinitely, and no alert fires because the pod that was supposed to process it is gone. A CronJob is just a Job on a schedule, exactly like a Linux cron tab but managed by Kubernetes and visible in the cluster's resource list.

### NetworkPolicies — the wall between services

By default, every pod in a Kubernetes cluster can talk to every other pod. That is completely fine for a personal project and a serious problem in a payment system, where it means a compromised notification service could open a direct connection to the wallet service's database.

PayFlow's `k8s/base/policies/network-policies.yaml` starts with a default deny — a policy that blocks all ingress and egress for every pod in the namespace — and then explicitly opens only the paths that should exist. The API gateway can receive traffic from outside and call any backend. Backend services can reach Postgres, Redis, and RabbitMQ but cannot call each other's HTTP APIs unless explicitly allowed. The transaction service specifically can reach the wallet service for transfers. The wallet service specifically can receive from the transaction service. Prometheus can scrape metrics from each service on its designated port. Nothing else is permitted.

What this means in practice is that a compromised notification pod is trapped in its lane. It cannot call the wallet service's API, it cannot reach arbitrary Redis keys, and the blast radius of any breach is bounded at the network layer before a single line of malicious code even runs — not by application logic, but by policy.

---

## Layer 3: CI/CD — the path from a git push to a running pod

### What CI/CD is and what it replaces

CI/CD stands for Continuous Integration and Continuous Deployment, and the simplest way to understand it is to imagine what deployment looks like without it. Without CI/CD, you build the Docker image on your laptop, push it to a registry, manually update a manifest, and apply it to the cluster. Every one of those steps is a place where something can go wrong, be forgotten, or produce a result that differs from what someone else would get doing the same thing.

CI/CD automates that chain and makes it consistent. Every change goes through the same steps in the same order, and the results are recorded and auditable.

### How PayFlow's pipeline actually works

Every push to the main branch triggers a GitHub Actions workflow that runs in three stages, and the order matters.

The first stage is validation, and it runs before any Docker image is built. The pipeline installs npm dependencies for all five backend services and the frontend. This sounds simple, but it catches broken package files and missing lockfiles before the build step wastes another five minutes building six images only to fail at the last one. If any service fails to install, the pipeline stops immediately and nothing proceeds.

Once validation passes, the build stage builds all six Docker images — API gateway, auth, wallet, transaction, notification, frontend — and pushes them to Docker Hub. All the Dockerfiles share the same build context at `./services/` so that the shared code in `services/shared/` is available inside every image, which avoids the situation where services have divergent copies of the same utility code. Each image gets tagged with two identifiers: `latest` and the short Git commit SHA — a seven-character string like `a3f9c12` that uniquely identifies the exact commit the image was built from. That SHA is what lets you look at a running pod months later and trace it back to a specific line of code.

When AWS credentials are configured, a third stage pushes all six images to ECR — Elastic Container Registry, which is AWS's private container registry. The reason for ECR rather than always pulling from Docker Hub is partly reliability (no external dependency at deploy time), partly rate limits (Docker Hub throttles unauthenticated pulls), and partly access control (ECR integrates with IAM, so only the right identities can pull images). Think of Docker Hub as a public library and ECR as a locked storage room inside your own building.

One thing worth being explicit about: the pipeline builds and publishes images but it does not deploy to the cluster automatically. A separate deploy script applies updated manifests to Kubernetes. That separation is intentional — every commit gets a versioned, immutable artifact, but you decide what actually gets shipped and when.

---

## Layer 4: Observability — knowing whether money is moving or silently frozen

### Monitoring is not the same thing as observability

Monitoring is watching a dashboard and seeing that a pod is up. Observability is having enough information to understand *why* something is wrong, even in a situation you have never seen before.

A lot of engineers conflate observability with logging, and that conflation is worth untangling because it is directly relevant to the scenario at the start of this article. Logs tell you what happened on a specific request after the fact — they are a record of past events. Metrics tell you how the system is behaving right now across all requests — they are a measurement of the present state. Without both, you cannot answer the question that matters most in a payment system: is money actually moving right now? The pods in the opening scenario were up, the logs showed no errors, but there was no metric tracking how many transactions were stuck in PENDING and no alert watching that metric. Logs alone would never have caught it.

Observability means having the signals to catch failures before a user has to call you about them.

### What PayFlow's monitoring stack looks like

PayFlow runs a full monitoring stack in its own `monitoring` namespace, and it has more pieces than most people expect. Prometheus is the metrics database — every service exposes a `/metrics` endpoint and Prometheus scrapes all of them on a schedule, storing the data as time-series (measurements recorded over time, like "transaction count was 42 at 14:00 and 47 at 14:01") and continuously evaluating alert rules against them.

Grafana sits on top of Prometheus and draws dashboards — transaction rates, error rates, latency percentiles, queue depth. The important thing about Grafana is what it does not do: it does not page anyone. Alerts do that, and they go through Alertmanager, which is the routing layer that decides who gets woken up and how — Slack, email, PagerDuty — when a Prometheus rule fires.

Loki handles log aggregation. When an alert fires and you need to understand why, you want to be able to jump from the metric ("transaction failure rate spiked at 14:02") directly to the log lines from that minute rather than searching through raw output. Loki stores logs from all pods in a format queryable with the same mental model as Prometheus metrics. Promtail is the agent that runs on every node, picks up logs from every container automatically, and ships them to Loki.

PostgreSQL and Redis do not natively speak Prometheus, so they each have an exporter — a small sidecar process that reads their internal stats and translates them into Prometheus format. This matters because it means you can alert on "database connection pool 90% full" or "Redis memory high" with exactly the same tooling as your application-level alerts, rather than needing a separate monitoring system for infrastructure. kube-state-metrics does the same thing for Kubernetes itself, turning cluster state into metrics: how many pods are running versus how many should be, whether the CronJob completed on schedule, whether resource quotas are close to their limits.

### The alerts that only exist because money is involved

Most of the alerts in `k8s/monitoring/alerts.yml` would exist in any serious system — service down, high error rate, slow response time, CoreDNS failures. The business alerts are the ones that are specific to fintech, and they are actually the most important category even though engineers new to payment systems tend to think infrastructure alerts come first. Infrastructure alerts catch platform failures. Business alerts catch the specific failure mode of a payment system — money that cannot move.

`PendingTransactionsStuck` fires when any transaction has been in `PENDING` status for more than two minutes. The description in the alert file is direct: "User funds are locked! Immediate investigation required." It is marked P0. `MoneyStuckInPendingTransactions` fires when more than $1,000 in total is sitting in pending transactions — not a theoretical threshold, but real money that real users cannot access. `OldestPendingTransactionTooOld` fires when the oldest pending transaction is more than two minutes old, which is significant because the CronJob reverses stuck transactions every minute, so anything older than two minutes means the CronJob itself has broken. `NoTransactionsProcessed` fires when no transactions at all have been processed in ten minutes, which usually means the system is dead even if the pods appear healthy.

There are also SLO alerts — SLO stands for Service Level Objective, which is a formal target you commit to. `SLOErrorBudgetBurning` fires when the error rate is high enough to exhaust the 99.9% availability target for the month. `LatencySLOViolation` fires when the 95th percentile response time at the API gateway exceeds 500ms. The 95th percentile means that 95% of requests completed faster than this — it is a better measure of user experience than the average, because averages hide the slow outliers that real users are actually experiencing.

### The custom metric that makes the whole thing work

The `PendingTransactionsStuck` alert only exists because someone added a custom metric to the transaction service. Every time a transaction enters PENDING status, the code increments `payflow_pending_transactions_total`. Every time it completes or fails, the code decrements it. Prometheus scrapes this every fifteen seconds and evaluates whether the alert should fire.

That metric does not exist in any off-the-shelf monitoring tool, and no default Prometheus installation will ever ship it, because it is specific to this domain. An engineer added it by asking "what is the worst thing that can happen in this system that generic monitoring would never catch?" — and the answer was money sitting frozen with nobody knowing. Off-the-shelf monitoring would have told you CPU was fine and the pod was running. This custom metric tells you money is stuck.

That is what the opening scenario was designed to show. The infrastructure was up, the pipeline was green, the pods were healthy — and without `payflow_pending_transactions_total` watching the business state of the system, there was no signal. Adding the metric and the alert is what closes the gap. That is what observability actually means in practice.

---

## How all four layers connect in a real deployment

When you push code to main, here is what actually happens. GitHub Actions triggers, the validate job installs dependencies for all services, and if any fail the whole thing stops before wasting time on builds. Assuming that passes, the build job produces six Docker images tagged with the commit SHA and pushes them to Docker Hub and ECR. An engineer then runs the deploy script, which updates the Kubernetes manifests to reference the new image tags and applies them to the cluster.

Kubernetes rolls out the new pods one at a time rather than all at once, so if the new pods fail their health checks the rollout stops and the old pods keep serving traffic — which is why the health checks are worth getting right. Prometheus is already scraping the new pods, so if error rates spike or latency climbs after the deploy, an alert fires within a couple of minutes rather than whenever the next user happens to notice. And if a transaction gets stuck during the rollout, the CronJob reverses it within the next minute; if the CronJob itself stops working, an alert fires for that too.

Each layer is catching a different class of failure: Terraform catches "the environment was not configured correctly," Kubernetes catches "the pod crashed and nobody restarted it," CI/CD catches "the code never arrived in the cluster or arrived broken," and observability catches "something is wrong but the pods look fine." Remove any one of them and you have a blind spot. This is the system you are looking at when you clone PayFlow.

---

## How to actually start reading this codebase

If you clone the repo and want to understand the infrastructure without drowning in YAML, do it in this order.

Start with `terraform/ARCHITECTURE-MAP.md`, which maps every resource and every dependency in plain text. You are not trying to understand every detail — you are trying to understand the shape. Then open `k8s/base/kustomization.yaml`, which is your table of contents for the cluster: everything listed there is always deployed, regardless of environment. After that, read the comments at the top of each section in `k8s/base/policies/network-policies.yaml` — they explain *why* each policy exists before you read a single rule. Then open `k8s/monitoring/alerts.yml` and just read the alert names and their descriptions. They tell you what the team decided was important enough to wake someone up for, which tells you more about the system's priorities than any architecture diagram. Finally, run it locally with `docker compose up` and open `localhost:9090`. Go to Status → Targets and look at the scrape results. Seeing healthy scrapes across all six services makes the whole observability model concrete in a way that reading about it does not.

You do not need to memorise every Terraform resource or understand every Kubernetes field. What you need is to know which layer owns which failure mode — so that when something breaks, you trace the problem to the right place instead of spending forty minutes looking at the wrong layer.

---

## What you can explain now that you could not before

You started this article with a scenario where everything looked fine — green pipeline, running pods, no errors — and money was frozen. Now you know exactly why that happens and what every layer of this infrastructure does to prevent it.

You can explain what Terraform builds before a single container ever starts, and why IRSA is the step that silently breaks everything when it is skipped. You can describe the hub-and-spoke VPC layout and what managed services separation means for the blast radius of a breach. You can explain the difference between a Kustomize base and an overlay, why that pattern exists, and how it differs from Helm. You can trace the exact path a code change takes from a git push to a running pod, and explain why the pipeline validates before it builds. You can explain why `PendingTransactionsStuck` matters more than `HighCPUUsage` in a payment system, and why logs alone would never have surfaced that problem. And you can explain why a pod showing `Running 1/1` is not the same thing as a service that is actually doing its job.

That is the infrastructure layer — and most engineers only encounter these patterns for the first time when something breaks in production. You have them now before that moment arrives.

---

## What's coming next in this series

- **Part 1** — How money moves through six microservices, and why each step exists.
- **Part 2** — The four concepts that break every fintech system: atomicity, idempotency, auditability, least privilege.
- **Part 3** — The infrastructure layer. (You are here.)
- **Part 4** — Operations and reliability. The timeout handler, home lab drills, SLOs, and what it actually means to run a payment system in production.

Follow to get each part as it drops.

→ PayFlow on GitHub

---

I write about DevOps weekly — real systems, real incidents, no fluff. → Join the newsletter
