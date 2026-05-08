import Testing

extension Tag {
    /// Marks a test that boots a real engine or other heavy external resource.
    /// Run with `--filter-tag integration` to exercise; skip in fast CI.
    @Tag static var integration: Self
}
