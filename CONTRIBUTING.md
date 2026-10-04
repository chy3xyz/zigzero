# Contributing to ZigZero

Thank you for your interest in contributing to ZigZero!

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/zigzero.git
   cd zigzero
   ```
3. **Install dependencies**:
   - Zig 0.17.0+
   - For `sqlx` module: `libsqlite3`, `libpq`, `libmysqlclient`
4. **Build and test**:
   ```bash
   zig build
   zig build test
   ```

## Development Workflow

### Branch Naming

- `feat/` — new features
- `fix/` — bug fixes
- `docs/` — documentation
- `refactor/` — code refactoring
- `test/` — adding or updating tests

Example: `feat/sqlx-transaction-retry`

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(api): add rate limiting middleware
fix(sqlx): resolve memory leak in connection pool
docs(readme): update installation instructions
test(breaker): add circuit breaker threshold tests
```

### Pull Request Process

1. **Create a feature branch** from `main`:
   ```bash
   git checkout -b feat/your-feature-name
   ```

2. **Make your changes** — ensure tests pass:
   ```bash
   zig build test
   ```

3. **Run the full test suite** with SQLite, PostgreSQL, and MySQL:
   ```bash
   # SQLite tests
   zig build test

   # PostgreSQL tests
   DB=postgres zig build test

   # MySQL tests
   DB=mysql zig build test
   ```

4. **Commit your changes** with a clear message:
   ```bash
   git add .
   git commit -m "feat(module): describe your change"
   ```

5. **Push and create a PR** on GitHub

## Code Style

### General Guidelines

- Follow Zig's [Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
- Use `camelCase` for function names
- Use `PascalCase` for types and structs
- Use `snake_case` for variables and functions (when not following Zig conventions)
- Prefer `const` over `var`
- Avoid unnecessary allocations
- Handle all errors explicitly — no empty `catch` blocks

### Documentation

- Add doc comments (`///`) to public functions and types
- Keep comments focused on the "why", not the "what"
- Update README.md if you add significant features

### Testing

- All new features should include tests
- Bug fixes should include a regression test
- Tests must pass without memory leaks (check for "leaked" in test output)
- DB-specific tests (postgres/mysql) should use `skipUnlessDb()` helper

Example test structure:
```zig
test "your feature description" {
    const allocator = std.testing.allocator;
    // ... test code
}
```

## Project Structure

```
src/
├── core/       # Core utilities (errors, threading, fx, mapreduce)
├── net/        # Network (api, http, rpc, websocket, gateway)
├── infra/      # Infrastructure (log, redis, pool, cache, sqlx, etc.)
├── server/     # Server middleware
├── data/       # Data layer (orm, validate)
├── config.zig  # Configuration
├── svc.zig     # Service context (DI)
└── zigzero.zig # Root module
```

## Reporting Issues

- Search existing issues first
- Include Zig version (`zig version`)
- Include OS and architecture
- For crashes, include stack trace
- For sqlx issues, include DB engine version

## Questions?

- Open a Discussion on GitHub
- Check the [Zig Discord](https://discord.gg/zig) for general Zig questions

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
