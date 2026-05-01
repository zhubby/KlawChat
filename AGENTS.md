# AGENTS.md

## Project Overview

This is an iOS Swift project. Any automated agent, AI assistant, or
developer modifying this codebase must prioritize code quality,
maintainability, consistency, and test coverage.

## Core Principles

-   Preserve existing architecture and coding style.
-   Keep changes minimal and focused.
-   Avoid unnecessary abstractions or dependencies.
-   Ensure all new logic is testable.
-   Do not include debug code, temporary code, or unused assets.

## Swift Code Style

### Naming

-   Types: UpperCamelCase
-   Variables, functions: lowerCamelCase
-   Booleans: use clear prefixes (is, has, should)
-   Avoid unclear abbreviations

### Structure

-   Keep files focused and small.
-   Separate concerns (View, ViewModel, Model, Service).
-   Avoid business logic in Views.
-   Prefer dependency injection over global state.
-   Avoid force unwraps.

### Error Handling

-   Use Result, throws, async throws.
-   Do not ignore errors silently.
-   Handle network, parsing, and permission failures explicitly.

### Concurrency

-   Use async/await and Swift Concurrency.
-   Ensure UI updates happen on MainActor.
-   Avoid uncontrolled detached tasks.
-   Handle cancellation properly.

### Memory Management

-   Use \[weak self\] in closures when appropriate.
-   Avoid retain cycles.

## UI Guidelines

### SwiftUI

-   Keep Views lightweight.
-   Move logic to ViewModels.
-   Avoid side effects in body.
-   Keep reusable components modular.

### UIKit

-   Avoid Massive View Controllers.
-   Separate layout, logic, and data handling.

## Architecture

-   Follow existing architecture (MVVM, Clean, etc.).
-   View: UI only
-   ViewModel: state + logic
-   Service: external dependencies

## Dependencies

-   Do not add dependencies without justification.
-   Prefer native APIs.
-   Ensure compatibility with deployment target.

## Testing

### Unit Tests

Cover:

-   ViewModels
-   Services
-   Business logic
-   Error cases
-   Edge cases

### UI Tests

Add when needed for:

-   Critical flows (login, payment, navigation)

### Test Practices

-   Clear test names
-   Test behavior, not implementation
-   Use mocks/stubs
-   No network dependency
-   Deterministic tests

## Dependency Injection

-   Use protocols for services.
-   Avoid direct instantiation in business logic.

## Code Review Checklist

-   Builds successfully
-   Tests pass
-   No warnings
-   No unused code
-   No debug logs
-   No sensitive data
-   Changes are scoped

## Security

-   No secrets in code
-   No sensitive logs
-   Handle permissions properly

## Performance

-   Avoid blocking main thread
-   Avoid redundant requests
-   Optimize lists and images

## Documentation

-   Document complex logic
-   Keep comments concise and useful

## Prohibited

-   Skipping tests
-   Deleting tests without replacement
-   Unrelated refactoring
-   Committing local configs

## Workflow

1.  Read existing code
2.  Define minimal change
3.  Write/update tests
4.  Implement
5.  Run tests
6.  Review changes

## Definition of Done

-   Works as expected
-   Matches code style
-   Covered by tests
-   No regressions
-   Maintainable and clear
