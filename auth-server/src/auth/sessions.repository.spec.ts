import { ConfigService } from '@nestjs/config';
import type pg from 'pg';
import type { Env } from '../config/env.js';
import { DEV_MFA_BYPASS_ACCOUNTS } from './dev-mfa-bypass.js';
import { SessionsRepository } from './sessions.repository.js';

describe('Session creation MFA policy', () => {
  function setup(enabled?: boolean, changes: Record<string, unknown> = {}, enrolled = false) {
    const identity = {
      email: 'dev.superadmin@example.com', password_hash: 'checked-password-hash',
      roles: ['SUPER_ADMIN'], mfa_required: true, disabled_at: null,
      password_change_required: false, ...changes,
    };
    const query = vi.fn(async (text: string) => {
      if (text.includes('FROM users')) return { rows: [identity] };
      if (text.includes('FROM user_mfa')) return { rows: enrolled ? [{ enabled_at: new Date() }] : [] };
      if (text.includes('INSERT INTO sessions')) return { rows: [{ id: 'session', user_id: 'user' }] };
      return { rows: [] };
    });
    const client = { query, release: vi.fn() };
    const pool = { connect: async () => client } as unknown as pg.Pool;
    const config = enabled === undefined ? undefined
      : new ConfigService<Env, true>({ DEV_MFA_BYPASS: enabled });
    const repository = new SessionsRepository(pool, config);
    return {
      query,
      create: (verified = true, expectedHash = 'checked-password-hash') => repository.create(
        'user', Buffer.alloc(32), new Date(Date.now() + 60000),
        new Date(Date.now() + 120000), undefined, verified, expectedHash,
      ),
    };
  }

  it.each(DEV_MFA_BYPASS_ACCOUNTS)('allows the enabled dev exception for %s without an authenticator', async (email) => {
    const { create, query } = setup(true, { email });
    await expect(create()).resolves.toMatchObject({ id: 'session' });
    expect(query).toHaveBeenCalledWith(expect.stringContaining('INSERT INTO sessions'),
      expect.arrayContaining([true]));
    expect(query).toHaveBeenCalledWith('COMMIT');
  });

  it.each([false, undefined])('requires enrollment when bypass configuration is %s', async (enabled) => {
    const { create, query } = setup(enabled);
    await expect(create()).rejects.toThrow('MFA verification is required');
    expect(query).toHaveBeenCalledWith('ROLLBACK');
    expect(query.mock.calls.some(([text]) => text.includes('INSERT INTO sessions'))).toBe(false);
  });

  it('does not bypass enrollment for accounts outside the list', async () => {
    await expect(setup(true, { email: 'staff@example.invalid' }).create()).rejects.toThrow('MFA verification is required');
  });

  it('still rejects a required-MFA session without verified proof', async () => {
    await expect(setup(true).create(false)).rejects.toThrow('MFA verification is required');
  });

  it.each([{ disabled_at: new Date() }, { password_change_required: true }])('still blocks disabled or temporary-password accounts: %j', async (changes) => {
    await expect(setup(true, changes).create()).rejects.toThrow('This account cannot sign in right now.');
  });

  it('rechecks the password under the user lock', async () => {
    await expect(setup(true).create(true, 'stale-password-hash')).rejects.toThrow('Credentials changed.');
  });

  it('allows normal enrolled MFA without the dev setting', async () => {
    await expect(setup(false, { email: 'staff@example.invalid' }, true).create()).resolves.toMatchObject({ id: 'session' });
  });

  it('preserves password-only login for clients who did not opt into MFA', async () => {
    await expect(setup(false, { email: 'client@example.invalid', roles: ['CLIENT'], mfa_required: false }).create(false))
      .resolves.toMatchObject({ id: 'session' });
  });
});
