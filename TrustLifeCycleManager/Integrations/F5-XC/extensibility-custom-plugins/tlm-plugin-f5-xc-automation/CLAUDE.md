# Project conventions for Claude

## Testing

- **Never use `@Nested` classes in JUnit 5 tests.** Keep all `@Test` methods flat at the top level of the test class. Use section-separator comments (e.g. `// ── Success path ───────────`) to group related tests visually.
- Use `@DisplayName` on every `@Test` for readable output.
- Name integration tests `*IT.java` and annotate with `@Tag("integration")` so `maven-failsafe-plugin` picks them up; `maven-surefire-plugin` should exclude `**/*IT.java`.
- Use WireMock (`org.wiremock:wiremock`) to stub HTTP in integration tests. Use Mockito only for SDK/framework constructor dependencies, not for the class under test.
