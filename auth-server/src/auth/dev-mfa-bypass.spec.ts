import { ForbiddenException, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import bcrypt from 'bcrypt';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import pg from 'pg';
import { TEST_ENV } from '../../test/test-env.js';
import { validateEnv, type Env } from '../config/env.js';
import { UsersRepository, type User } from '../users/users.repository.js';
import { AuthService } from './auth.service.js';
import { DEV_MFA_BYPASS_ACCOUNTS } from './dev-mfa-bypass.js';
import { MfaService } from './mfa.service.js';
import { SessionsRepository } from './sessions.repository.js';
import { TokenService } from './token.service.js';

// Temporary dev switch (dev-mfa-bypass.ts). Delete this file together with it.
const password = 'EndgameDemo123!';
const settings = (devMfaBypass: boolean) =>
  new ConfigService<Env, true>({
    ...TEST_ENV,
    ACCESS_TOKEN_TTL: '15m',
    SESSION_IDLE_TIMEOUT_MINUTES: 30,
    SESSION_MAX_AGE_HOURS: 12,
    MFA_ENCRYPTION_KEY: randomBytes(32).toString('base64'),
    DEV_MFA_BYPASS: devMfaBypass,
  });

describe('DEV_MFA_BYPASS setting', () => {
  it('is off unless set to a true value, and a typo stops startup', () => {
    expect(validateEnv({ ...TEST_ENV }).DEV_MFA_BYPASS).toBe(false);
    expect(validateEnv({ ...TEST_ENV, DEV_MFA_BYPASS: 'false' }).DEV_MFA_BYPASS).toBe(false);
    expect(validateEnv({ ...TEST_ENV, DEV_MFA_BYPASS: 'true' }).DEV_MFA_BYPASS).toBe(true);
    expect(() => validateEnv({ ...TEST_ENV, DEV_MFA_BYPASS: 'maybe' })).toThrow('DEV_MFA_BYPASS');
  });
});

// Login decisions with in-memory fakes: nobody has an authenticator, so without the switch
// every staff account is sent to enrollment.
describe('Dev MFA switch: login', () => {
  const hash = bcrypt.hashSync(password, 4);
  const roles = ['SUPER_ADMIN', 'ADMIN', 'ANALYST'];
  let accounts: Map<string, User>;
  let sessionCreate: ReturnType<typeof vi.fn>;
  let tokens: TokenService;

  beforeEach(() => {
    accounts = new Map();
    DEV_MFA_BYPASS_ACCOUNTS.forEach((email, i) => accounts.set(email, { id: randomUUID(), email, passwordHash: hash, roles: [roles[i]] }));
    accounts.set('david.admin@example.com', { id: randomUUID(), email: 'david.admin@example.com', passwordHash: hash, roles: ['ADMIN'] });
    sessionCreate = vi.fn(async () => ({}));
  });

  function service(devMfaBypass: boolean) {
    const config = settings(devMfaBypass);
    tokens = new TokenService(config);
    return new AuthService(
      { findByEmail: async (email: string) => accounts.get(email) ?? null } as unknown as UsersRepository,
      { create: sessionCreate } as unknown as SessionsRepository,
      tokens,
      config,
      {
        enabled: async () => false,
        start: async (user: User, purpose: string) => ({ mfaRequired: true, challengeToken: user.id, purpose }),
      } as unknown as MfaService,
    );
  }

  it('switch off: a dev account gets the MFA step like any staff account', async () => {
    expect(await service(false).login('dev.admin@example.com', password)).toMatchObject({ mfaRequired: true, purpose: 'enroll' });
    expect(sessionCreate).not.toHaveBeenCalled();
  });

  it.each(DEV_MFA_BYPASS_ACCOUNTS.map((email, i) => [email, roles[i]]))(
    'switch on: %s gets tokens carrying MFA proof, from an MFA-verified session',
    async (email, role) => {
      const result = await service(true).login(email, password);
      if (!('accessToken' in result)) throw new Error(`Expected tokens, got ${JSON.stringify(result)}`);
      const claims = tokens.validateAccessToken(result.accessToken);
      expect(claims).toMatchObject({ amr: ['pwd', 'mfa'], roles: [role] });
      expect(claims.aud).toContain('endgame-staff');
      // 6th argument of SessionsRepository.create is mfaVerified.
      expect(sessionCreate.mock.calls[0][5]).toBe(true);
    },
  );

  it('switch on: staff outside the list still need MFA', async () => {
    expect(await service(true).login('david.admin@example.com', password)).toMatchObject({ mfaRequired: true });
  });

  it('switch on: a wrong password, a disabled account and a pending password change still win', async () => {
    const auth = service(true);
    await expect(auth.login('dev.admin@example.com', 'wrong-password')).rejects.toThrow(UnauthorizedException);
    accounts.get('dev.admin@example.com')!.disabledAt = new Date();
    await expect(auth.login('dev.admin@example.com', password)).rejects.toThrow(ForbiddenException);
    accounts.get('dev.analyst@example.com')!.passwordChangeRequired = true;
    expect(await auth.login('dev.analyst@example.com', password)).toEqual({ passwordChangeRequired: true });
    expect(sessionCreate).not.toHaveBeenCalled();
  });
});

// The real schema and seed: the dev accounts' locked user_mfa rows, the session check and refresh.
describe.skipIf(!process.env.MFA_TEST_DATABASE_URL)('Dev MFA switch: PostgreSQL with the real seed', () => {
  let db: pg.Pool;
  let tokens: TokenService;
  const auth = (devMfaBypass: boolean) => {
    const config = settings(devMfaBypass);
    tokens = new TokenService(config);
    return new AuthService(new UsersRepository(db), new SessionsRepository(db, config), tokens, config, new MfaService(db, config as unknown as ConfigService));
  };

  beforeAll(async () => {
    db = new pg.Pool({ connectionString: process.env.MFA_TEST_DATABASE_URL });
    await db.query(await readFile('../DB/auth_db.schema.sql', 'utf8'));
    await db.query(await readFile('../DB/auth_db_test_data.sql', 'utf8'));
  });
  afterAll(async () => {
    await db?.end();
  });

  it.each(DEV_MFA_BYPASS_ACCOUNTS)('switch on: %s signs in without a code, and refresh keeps the MFA proof', async (email) => {
    const service = auth(true);
    const pair = await service.login(email, password);
    if (!('accessToken' in pair)) throw new Error(`Expected tokens, got ${JSON.stringify(pair)}`);
    const { sub } = tokens.validateAccessToken(pair.accessToken);
    const session = (await db.query('SELECT mfa_verified_at FROM sessions WHERE user_id=$1 ORDER BY created_at DESC LIMIT 1', [sub])).rows[0];
    expect(session.mfa_verified_at).not.toBeNull();
    // start-project.sh re-applies the schema on every start; it must not revoke this session.
    await db.query(await readFile('../DB/auth_db.schema.sql', 'utf8'));
    const refreshed = await service.refresh(pair.refreshToken);
    expect(tokens.validateAccessToken(refreshed.accessToken)).toMatchObject({ amr: ['pwd', 'mfa'] });
  });

  it('a newly provisioned dev account can change its temporary password and sign in without a fixture MFA row', async () => {
    const email = 'dev.superadmin@example.com';
    const original = (await db.query('SELECT id,password_hash FROM users WHERE email=$1', [email])).rows[0];
    const mfa = (await db.query('SELECT enabled_at,locked_until FROM user_mfa WHERE user_id=$1', [original.id])).rows[0];
    const newPassword = 'new-private-dev-password-123';
    try {
      await db.query('DELETE FROM user_mfa WHERE user_id=$1', [original.id]);
      await db.query('UPDATE users SET password_change_required=true WHERE id=$1', [original.id]);
      const service = auth(true);
      expect(await service.login(email, password)).toEqual({ passwordChangeRequired: true });
      const pair = await service.changeTemporaryPassword(email, password, newPassword);
      if (!('accessToken' in pair)) throw new Error('Expected a completed login after changing the password');
      expect(tokens.validateAccessToken(pair.accessToken)).toMatchObject({ roles: ['SUPER_ADMIN'], amr: ['pwd', 'mfa'] });
      const refreshed = await service.refresh(pair.refreshToken);
      expect(tokens.validateAccessToken(refreshed.accessToken).amr).toContain('mfa');
      expect((await db.query('SELECT count(*)::int AS n FROM user_mfa WHERE user_id=$1', [original.id])).rows[0].n).toBe(0);
      const withoutBypass = await auth(false).login(email, newPassword);
      expect('mfaRequired' in withoutBypass && withoutBypass.mfaRequired).toBe(true);
    } finally {
      await db.query('UPDATE users SET password_hash=$2,password_change_required=false WHERE id=$1', [original.id, original.password_hash]);
      await db.query('DELETE FROM user_mfa WHERE user_id=$1', [original.id]);
      await db.query('INSERT INTO user_mfa(user_id,enabled_at,locked_until) VALUES($1,$2,$3)', [original.id,mfa.enabled_at,mfa.locked_until]);
    }
  });

  it('switch off: dev accounts can neither sign in nor set up or replace an authenticator', async () => {
    const service = auth(false);
    for (const email of DEV_MFA_BYPASS_ACCOUNTS) {
      await expect(service.login(email, password)).rejects.toThrow(UnauthorizedException);
      await expect(service.startMfa(email, password, 'enroll')).rejects.toThrow();
      await expect(service.startMfa(email, password, 'replace')).rejects.toThrow();
    }
  });

  it('switch on: seeded staff outside the list still need MFA', async () => {
    expect(await auth(true).login('priya.analyst@example.com', password)).toMatchObject({ mfaRequired: true });
  });
});
