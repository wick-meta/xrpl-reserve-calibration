# Security Policy

## Supported versions

Security fixes are applied to the current `main` branch. No released version is supported until the project publishes one.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for this repository. Do not include a wallet seed, private key, credential, personal data, or a live exploit against infrastructure you do not own. Include the affected commit, reproduction conditions, expected impact, and a minimal safe proof of concept.

Maintainers will acknowledge a report, assess severity, coordinate remediation, and publish a disclosure when it is safe to do so. No service-level response time is promised.

## Scope

The observer must remain read-only. Any path that can construct, sign, or submit a transaction is a security-sensitive design change and requires explicit threat modelling before implementation.
