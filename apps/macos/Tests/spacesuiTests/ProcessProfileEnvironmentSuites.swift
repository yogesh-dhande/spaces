import Testing

/// Shared serialization domain for every Swift Testing suite that mutates the process-global profile
/// environment (`SPACES_DB_PATH` / `SPACES_RUNTIME_DIR`) in its `init`/`deinit`. Swift Testing runs
/// distinct suites in parallel within one `swift test` process by default, and a suite's own
/// `.serialized` trait only orders the tests *within* that suite — it does nothing to keep two such
/// suites from running at the same time and clobbering (or deleting) each other's temp profile root
/// mid-test.
///
/// `.serialized` applies recursively to nested suites, so every suite that overrides those two
/// environment variables must nest under this parent (`extension ProcessProfileEnvironmentSuites {
/// @Suite final class Foo { ... } }`) instead of declaring its own top-level `@Suite`. That keeps every
/// nested suite serialized relative to every other one, which is what prevents the interleaving this
/// type exists to rule out.
@Suite(.serialized) enum ProcessProfileEnvironmentSuites {}
