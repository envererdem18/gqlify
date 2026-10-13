/// Codecs for custom scalars, referenced from `gqlify.yaml`.
library;

String encodeDateTime(DateTime value) => value.toUtc().toIso8601String();
