import 'exceptions.dart';

/// JSON object type used by the `toJson` / `fromJson` methods of the models.
typedef JsonMap = Map<String, Object?>;

/// Reads a required number from [json].
double readDouble(JsonMap json, String key) {
  final value = json[key];
  if (value is num && value.isFinite) return value.toDouble();
  throw ColorDataFormatException('Expected a number for "$key", got $value');
}

/// Reads a required integer from [json].
int readInt(JsonMap json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  throw ColorDataFormatException('Expected an integer for "$key", got $value');
}

/// Reads a required string from [json].
String readString(JsonMap json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw ColorDataFormatException('Expected a string for "$key", got $value');
}

/// Reads an optional string from [json].
String? readOptionalString(JsonMap json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw ColorDataFormatException('Expected a string for "$key", got $value');
}

/// Reads a required nested object from [json].
JsonMap readMap(JsonMap json, String key) {
  final value = json[key];
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw ColorDataFormatException('Expected an object for "$key", got $value');
}

/// Reads an optional nested object from [json].
JsonMap? readOptionalMap(JsonMap json, String key) => json[key] == null ? null : readMap(json, key);

/// Reads a required list of objects from [json].
List<JsonMap> readMapList(JsonMap json, String key) {
  final value = json[key];
  if (value is! List) {
    throw ColorDataFormatException('Expected a list for "$key", got $value');
  }
  return [
    for (final item in value)
      if (item is Map)
        item.cast<String, Object?>()
      else
        throw ColorDataFormatException('Expected objects in "$key", got $item'),
  ];
}

/// Reads a required ISO-8601 timestamp from [json].
DateTime readDateTime(JsonMap json, String key) {
  final raw = readString(json, key);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw ColorDataFormatException('Invalid timestamp for "$key": $raw');
  }
  return parsed;
}
