# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.2.x   | ✅                 |
| 0.1.x   | ❌ (upgrade to 0.2.x) |
| < 0.1   | ❌                 |

## Reporting a Vulnerability

If you discover a security vulnerability within ZigZero, please report it responsibly:

1. **Do NOT** create a public GitHub issue
2. Email the maintainers directly or use GitHub's private vulnerability reporting
3. Include as much detail as possible:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Security Best Practices

When using ZigZero in production:

- **JWT secrets**: Use strong, randomly generated secrets stored securely (environment variables, secrets manager)
- **Database credentials**: Never commit credentials to version control; use environment variables or configuration files outside the repo
- **TLS certificates**: Use valid certificates from trusted CAs in production
- **Input validation**: Always validate user input, even if middleware handles it
- **Rate limiting**: Enable rate limiting on public endpoints
- **Circuit breakers**: Use circuit breakers to prevent cascading failures

## Dependencies

ZigZero's security depends on:

- **Zig compiler**: Ensure you're using a stable, up-to-date Zig release
- **System C libraries** (optional, for `sqlx`):
  - Keep `libpq`, `libmysqlclient`, `libsqlite3` updated for security patches
  - Use connection encryption (TLS) for database connections in production
