# Superset 6.1.0 upgrade review — 2026-10-29

Local candidate only. The application's default Dockerfile and published
Superset image remain on 6.0.0. No production metadata migrations were run.

## Results

- Latest stable package release checked: 6.1.0; 7.0.0rc2 is a prerelease.
- Dependency resolution and `uv pip check` passed.
- Seven SSO regression tests passed.
- Initialized fresh local PostgreSQL metadata with our 6.0 image, then ran the
  6.1 migration, permission initialization, and existing dashboard bootstrap.
- After migration: three dashboards, nine charts, three embedded IDs and three
  reporting-registry entries. This does not verify production-authored layouts
  or browser rendering; the database contained synthetic local configuration.
- Trivy 0.76.1: 7 critical, 105 high, 183 medium, 176 low, 1 unknown findings.
  The patched 6.0 candidate had 7 critical and 117 high findings.
- Resolved Pillow 12.3.0 and cryptography 46.0.5. Superset 6.1 requires Pillow
  below 13, cryptography below 47, msgpack below 1.1 and pyarrow below 19.
  These constraints still exclude fixes reported for remaining vulnerabilities.

**Decision:** candidate is not approved for deployment. Moving to 6.1 alone does
not clear the critical findings. Assess remaining advisories and upstream fixes
before a production upgrade. Do not force incompatible dependency versions or
run a metadata migration as part of routine container startup.

## Reproduce the candidate build

Use an isolated copy of `admin-analytics/superset` as the build context, excluding
environment files and caches. Replace that copy's Dockerfile and
security-requirements.txt with the two review files in this directory, then build
for linux/amd64 with Docker's host build network. Keep production credentials
out of the context. The reviewed local tag is
`asset-avengers-security-superset:review-6.1.0`; its exact image ID and scan
summary are recorded in `verification.json`.

Sources: [package requirements](https://pypi.org/pypi/apache-superset/6.1.0/json),
[upgrade notes](https://github.com/apache/superset/blob/6.1.0/UPDATING.md),
[Apache releases](https://github.com/apache/superset/releases).
