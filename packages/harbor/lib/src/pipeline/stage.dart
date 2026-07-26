/// Marker mixin for pipeline stage enums.
///
/// Users define their own stage enums with this mixin for compile-time
/// safety: no string typos for stage names:
///
/// ```dart
/// enum RiverStage with HarborPipelineStage {
///   fetch, decode, execute, writeback
/// }
///
/// enum SimpleStage with HarborPipelineStage {
///   input, process, output
/// }
/// ```
mixin HarborPipelineStage on Enum {}
