/// Custom scalar codecs referenced from gqlify.yaml.
String encodeDateTime(DateTime value) => value.toUtc().toIso8601String();
