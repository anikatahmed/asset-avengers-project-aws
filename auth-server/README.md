> For the current ECS/RDS/S3 deployment, follow [AWS runtime setup](../deployment/aws-runtime.md). Local database/container commands below apply only to local testing.

# Authentication service

For its connections to both Java APIs and the client/staff UIs, see the
[project guide](../docs/project-guide.md), [code map](../docs/code-map.md#authentication-auth-server)
and [database reference](../DB/README.md#auth-tables).

NestJS service for registration, bcrypt password verification, signed access JWTs,
refresh-token rotation and session revocation. The current auth PostgreSQL database
stores credentials, roles, sessions and hashed refresh tokens. It stores no portfolio data.

See the [complete project guide](../docs/project-guide.md) for architecture and database relationships.

Authenticator MFA is optional for client signup (`mfaEnabled`, default false), and
required for staff and enrolled accounts. Password login returns tokens directly
for clients without MFA, otherwise setup or a verification challenge. See [MFA](../docs/mfa.md) for signup, logout, replacement,
recovery codes and the Spring `amr` claim. The root `MFA_ENCRYPTION_KEY` must stay
stable. Existing demo identities enroll at first login; fixtures store no shared
secrets. **Forgot password?** uses Resend and the root `RESEND_API_KEY` sending key.
Email reset preserves the authenticator; signup email verification stays off for
testing. See [email setup and reset examples](../docs/email-service.md).

## Run and test

The repo-root `.env` supplies settings listed in `../.env.example` and `src/config/env.ts`.
The JWT secret must match the Spring backend. No SQL migration npm scripts currently exist.

```bash
# From the repository root: build the configured database/auth services.
bash scripts/start-project.sh --all

# From auth-server, after installing locked dependencies:
npm ci
npm run start:dev
npm test
npm run test:e2e
```

Auth DB schema: `../DB/auth_db.schema.sql`. Development login fixtures:
`../DB/auth_db_test_data.sql`. Docker applies those files only on initial empty-volume startup.
Do not delete database storage to perform a normal rebuild.

Swagger: `http://localhost:3000/api`. Routes: `POST /auth/register`, `/auth/login`,
`/auth/refresh`, `/auth/logout`. Health: `GET /health/live`, `/health/ready`.
The Angular app keeps access tokens in memory and refresh tokens in per-tab sessionStorage.
Reusing a rotated refresh token revokes its session. Logout does not delete trading data.

Signup requires `firstName` and `lastName` as well as email/password (trimmed,
nonblank, max 100 characters each). Auth `users` owns these names. Login/refresh
JWTs carry `given_name`, `family_name` and full `name`; missing legacy names fall
back to email in the UI. Existing auth volumes need the updated auth schema;
`bash scripts/start-project.sh` applies it before rebuilding services. Trading
copies signed name claims for downstream staff searches; it does not own names.

J.A.R.V.I.S. Superset SSO uses a stable root `SUPERSET_SSO_SECRET` (32+ characters),
one-use hashed handoffs and revocable leases bound to live MFA staff sessions.
See [SSO endpoints and deployment](../docs/jarvis-superset-workspace.md).

Staff sessions (ADMIN/ANALYST) have a fixed eight-hour MFA lifetime, including idle time. Refresh does not extend it; access JWT expiry is capped at the session deadline and carries `session_exp`. Superset enforces the same proof age. Explicit logout always requires MFA on the next login. Client timeout environment variables remain client settings. See [MFA guide](../docs/mfa.md#staff-eight-hour-mfa-window) for examples and the staff console's in-memory session limitation.
