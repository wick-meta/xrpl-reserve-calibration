# frozen_string_literal: true

require "time"

module TestSchemaValidator
  module_function

  def valid?(schema, value, root = schema)
    schema = resolve(root, schema.fetch("$ref")) if schema.key?("$ref")
    return false if schema["allOf"] && !schema.fetch("allOf").all? { |entry| valid?(entry, value, root) }
    return false if schema["oneOf"] && schema.fetch("oneOf").count { |entry| valid?(entry, value, root) } != 1
    return false if schema.key?("const") && value != schema["const"]
    return false if schema.key?("enum") && !schema["enum"].include?(value)
    return false unless valid_type?(schema["type"], value)
    return false if value.is_a?(Numeric) && schema["minimum"] && value < schema["minimum"]
    return false if value.is_a?(Numeric) && schema["maximum"] && value > schema["maximum"]
    if value.is_a?(String)
      return false if schema["minLength"] && value.length < schema["minLength"]
      return false if schema["maxLength"] && value.length > schema["maxLength"]
      return false if schema["pattern"] && !ecmascript_pattern?(schema["pattern"], value)
      return false if schema["format"] == "date-time" && !date_time?(value)
    end
    if value.is_a?(Hash)
      required = schema.fetch("required", [])
      return false unless (required - value.keys).empty?
      properties = schema.fetch("properties", {})
      return false if schema["additionalProperties"] == false && !(value.keys - properties.keys).empty?
      return false unless value.all? { |key, nested| !properties.key?(key) || valid?(properties[key], nested, root) }
    end
    if value.is_a?(Array) && schema["items"]
      return false unless value.all? { |nested| valid?(schema["items"], nested, root) }
      return false if schema["uniqueItems"] && value.uniq.length != value.length
    end
    true
  rescue ArgumentError, KeyError
    false
  end

  def resolve(root, reference)
    reference.delete_prefix("#/").split("/").reduce(root) { |value, key| value.fetch(key) }
  end

  def valid_type?(type, value)
    return true unless type
    { "object" => Hash, "array" => Array, "string" => String, "integer" => Integer,
      "number" => Numeric, "boolean" => [TrueClass, FalseClass] }.fetch(type).then do |classes|
      Array(classes).any? { |klass| value.is_a?(klass) } && !(type == "number" && value.is_a?(Complex))
    end
  rescue KeyError
    false
  end

  def date_time?(value)
    Time.iso8601(value)
    true
  rescue ArgumentError
    false
  end

  def ecmascript_pattern?(pattern, value)
    source = pattern.start_with?("^") ? "\\A#{pattern.delete_prefix('^')}" : pattern
    Regexp.new(source).match?(value)
  end
end
