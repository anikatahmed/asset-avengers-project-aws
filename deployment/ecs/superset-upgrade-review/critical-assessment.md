# Critical finding assessment — 2026-10-29

Scope: local Superset 6.1.0 review image in verification.json, plus read-only
inspection of the current EC2 Superset configuration. This assesses seven
critical scanner findings; it does not accept all other findings or establish
that the whole application is free of vulnerabilities.

| Finding | Verified prerequisites and application paths | Assessment |
| --- | --- | --- |
| CVE-2023-45853, zlib | Debian states contrib/minizip is not built into its bookworm zlib package. Candidate has no installed MiniZip package. | Not applicable to this binary package based on vendor guidance. Keep the finding visible. |
| CVE-2025-7458, SQLite | Candidate SQLite 3.40.1 is affected. Live metadata and the single configured reporting datasource use PostgreSQL. Unsafe-connection prevention is enabled. | Vulnerable component is present, but no configured application SQLite query path was found. Reassess before adding SQLite connections or changing metadata backend. |
| CVE-2026-112393, Pillow TIFF output | Requires saving compressed TIFF to a target without a file descriptor. Examined Superset image paths save PNG or PDF from screenshots. | No affected TIFF output path identified in the configured dashboard workflow. Not a package fix. |
| CVE-2026-112398, Pillow FlashPix | Requires optional olefile and crafted FPX input. Candidate olefile is absent. | Required dependency is absent. Reassess if olefile is installed. |
| CVE-2026-112403, Pillow JPEG | Candidate libjpeg-turbo 3.1.4.1 meets the vulnerable native-library prerequisite. Advisory additionally requires draft/thumbnail scaling of malicious lossless JPEG. Examined screenshot resizing uses resize(), not draft()/thumbnail(). | Potentially affected decoder remains. No matching configured input/scaling path identified; keep screenshot/report features disabled. |
| CVE-2026-112900, Pillow EPS | Requires invoking Ghostscript with attacker-controlled filenames. Candidate Ghostscript executable is absent. | Required executable is absent. Reassess if Ghostscript is installed. |
| CVE-2026-96639, Pillow multi-frame images | Requires processing crafted frame/mode transitions. Examined Superset screenshot paths open browser screenshots and do not traverse image frames. | No affected frame-transition path identified in this workflow. Keep untrusted server-side image processing disabled. |

The SQL/image findings remain real component vulnerabilities where noted.
Absence of a matching path in this inspection is not proof that every possible
path is unreachable. Do not describe these packages as patched or suppress
scanner findings as a substitute for remediation.

## Controls and deployment conditions

Repository configuration now explicitly disables THUMBNAILS, ALERT_REPORTS and
PLAYWRIGHT_REPORTS_AND_THUMBNAILS, preserving embedded dashboards and reporting
pipeline jobs. These flags concern Superset screenshot/email reports, not the
application's PostgreSQL reporting pipeline. Retain PostgreSQL metadata and
reporting connections, unsafe-connection prevention, restricted reporting
credentials, and existing SSO/guest-token checks. Do not add image-processing
dependencies or enable the disabled features without reassessment.

Production read-only checks found PostgreSQL metadata, one PostgreSQL reporting
datasource, no DML on that datasource, and unsafe-connection prevention enabled.
Its datasource is exposed in SQL Lab; this inspection does not change that
setting or grant users SQL Lab permissions. Raw feature overrides did not contain
the three screenshot flags; vendor defaults are false. The explicit repository
overrides prevent relying on those defaults after deployment.

Superset 6.1 requires a deliberate metadata migration. Before a production
migration, take and verify a protected metadata backup, test a production-like
restore, preserve dashboard IDs/layouts, and prepare rollback. Synthetic local
migration tests alone do not establish compatibility with production metadata.

ECS compute selection and deployment networking must be settled before creating
services. Kafka's current advertised hostname is Docker-local (`kafka:9092`);
do not launch Fargate publisher/consumer tasks against it or duplicate the
existing publisher/scheduler. A broker connectivity and persistence plan is
required before moving that part of the stack.

## Primary sources

- [Debian zlib assessment](https://security-tracker.debian.org/tracker/CVE-2023-45853)
- [Debian SQLite assessment](https://security-tracker.debian.org/tracker/CVE-2025-7458)
- [Pillow TIFF advisory](https://github.com/python-pillow/Pillow/security/advisories/GHSA-332p-7hrc-92wf)
- [Pillow FlashPix advisory](https://github.com/python-pillow/Pillow/security/advisories/GHSA-5x8w-8jj5-q52h)
- [Pillow JPEG advisory](https://github.com/python-pillow/Pillow/security/advisories/GHSA-8g5g-8vmr-9782)
- [Pillow EPS advisory](https://github.com/python-pillow/Pillow/security/advisories/GHSA-w889-685w-c8fh)
- [Pillow frame-transition advisory](https://github.com/python-pillow/Pillow/security/advisories/GHSA-v9pv-5gc8-w2m6)
