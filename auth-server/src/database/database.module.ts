import {
  Global,
  Inject,
  Logger,
  Module,
  OnApplicationShutdown,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import pg from 'pg';
import type { Env } from '../config/env.js';

// Injection token for the connection pool. Classes ask for it with
// `@Inject(PG_POOL) private readonly db: pg.Pool`.
export const PG_POOL = Symbol('PG_POOL');

// @Global() means every other module can inject PG_POOL without importing this one.
@Global()
@Module({
  providers: [
    {
      provide: PG_POOL,
      inject: [ConfigService],
      // useFactory runs once at startup; its return value is the shared instance.
      useFactory: (config: ConfigService<Env, true>) => {
        const pool = new pg.Pool({
          host: config.get('AUTH_DB_HOST', { infer: true }),
          port: config.get('AUTH_DB_PORT', { infer: true }),
          database: config.get('AUTH_DB_NAME', { infer: true }),
          user: config.get('AUTH_DB_USER', { infer: true }),
          password: config.get('AUTH_DB_PASSWORD', { infer: true }),
          ssl: config.get('AUTH_DB_SSL', { infer: true })
            ? { rejectUnauthorized: true, ca: config.get('AUTH_DB_SSL_CA', { infer: true }) || undefined }
            : false,
          max: 10,
        });
        // Without this listener, an idle connection dying (e.g. Postgres restarts)
        // would crash the whole process.
        pool.on('error', (err) =>
          new Logger('Database').error(`idle client error: ${err.message}`),
        );
        return pool;
      },
    },
  ],
  exports: [PG_POOL],
})
export class DatabaseModule implements OnApplicationShutdown {
  constructor(@Inject(PG_POOL) private readonly pool: pg.Pool) {}

  // Called by Nest on SIGTERM/SIGINT because main.ts enables shutdown hooks.
  async onApplicationShutdown() {
    await this.pool.end();
  }
}
