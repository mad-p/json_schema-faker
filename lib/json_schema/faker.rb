require "json_schema"

require "pxeger"

module JsonSchema
  class Faker
    module Configuration
      attr_accessor :logger

      module_function :logger, :logger=
    end

    # TODO:
    # strategy to use for faker
    def initialize(schema, options = {})
      @schema  = schema

      @options = options
    end

    def generate(hint: nil)
      generated = _generate(@schema, hint: nil, position: "")

      Configuration.logger.debug "to generate against #{@schema.inspect_schema}" if Configuration.logger
      Configuration.logger.debug "generated: #{generated.inspect}" if Configuration.logger

      generated
    end

    protected
    def _generate(schema, hint: nil, position:)
      Configuration.logger.debug "current position: #{position}" if Configuration.logger

      raise "here comes nil for schema at #{position}" unless schema

      return schema.default if schema.default

      if schema.not
        hint ||= {}
        # too difficult
        # TODO: support one_of/any_of/all_of
        hint[:not_have_keys] = schema.not.required if schema.not.required
        hint[:not_be_values] = schema.not.enum     if schema.not.enum
      end

      # TODO: should support the combinations of them
      # http://json-schema.org/latest/json-schema-validation.html#anchor75
      # Notes:
      # one_of, any_of, all_of, properties and type is given default and never be nil
      if    !schema.one_of.empty?
        generate_for_one_of(schema, hint: hint, position: position)
      elsif !schema.any_of.empty?
        generate_for_any_of(schema, hint: hint, position: position)
      elsif !schema.all_of.empty?
        generate_for_all_of(schema, hint: hint, position: position)
      elsif schema.enum
        generate_by_enum(schema, hint: hint, position: position)
      elsif !schema.type.empty?
        generate_by_type(schema, position: position)
      else # consider as object
        generate_for_object(schema, hint: hint, position: position)
      end
    end

    def generate_for_one_of(schema, hint: nil, position:)
      _generate(schema.one_of.first, hint: hint, position: "position/one_of[0]")
    end

    def generate_for_any_of(schema, hint: nil, position:)
      _generate(schema.any_of.first, hint: hint, position: "position/any_of[0]")
    end

    def generate_for_all_of(schema, hint: nil, position:)
      # deep_merge all_of
      merged_schema = JsonSchema::Schema.new
      merged_schema.copy_from(schema.all_of.first)

      schema.all_of[1..-1].each do |sub_schema|
        # attr not supported now
        # any_of:     too difficult...
        # enum/items: TODO: just get and of array
        # not:        too difficult (if `not` is not wrapped by all_of wrap it?)
        # multiple_of TODO: least common multiple
        # pattern:    too difficult...
        # format      TODO: just override

        # array properties
        %i[ type one_of all_of ].each do |attr|
          merged_schema.__send__("#{attr}=", merged_schema.__send__(attr) + sub_schema.__send__(attr))
        end
        merged_schema.required = (merged_schema.required ? merged_schema.required + sub_schema.required : sub_schema.required) if sub_schema.required

        # object properties
        # XXX: key conflict
        %i[ properties pattern_properties dependencies ].each do |attr|
          merged_schema.__send__("#{attr}=", merged_schema.__send__(attr).merge(sub_schema.__send__(attr)))
        end

        # override to stronger validation
        %i[ additional_items additional_properties ].each do |attr|
          merged_schema.__send__("#{attr}=", false) unless merged_schema.__send__(attr) && sub_schema.__send__(attr)
        end
        %i[ min_exclusive max_exclusive unique_items ].each do |attr|
          merged_schema.__send__("#{attr}=", merged_schema.__send__(attr) & sub_schema.__send__(attr))
        end
        %i[ min min_length min_properties ].each do |attr|
          if sub_schema.__send__(attr)
            if merged_schema.__send__(attr)
              merged_schema.__send__("#{attr}=", sub_schema.__send__(attr)) if sub_schema.__send__(attr) < merged_schema.__send__(attr)
            else
              merged_schema.__send__("#{attr}=", sub_schema.__send__(attr))
            end
          end
        end
        %i[ max max_length max_properties ].each do |attr|
          if sub_schema.__send__(attr)
            if merged_schema.__send__(attr)
              merged_schema.__send__("#{attr}=", sub_schema.__send__(attr)) if sub_schema.__send__(attr) > merged_schema.__send__(attr)
            else
              merged_schema.__send__("#{attr}=", sub_schema.__send__(attr))
            end
          end
        end
      end

      _generate(merged_schema, hint: hint, position: "position/all_of")
    end

    def generate_for_object(schema, hint: nil, position:)
      # http://json-schema.org/latest/json-schema-validation.html#anchor53
      if schema.required
        keys   = schema.required
        required_length = schema.min_properties || keys.length

        object = keys.each.with_object({}) do |key, hash|
          hash[key] = _generate(schema.properties[key], hint: hint, position: "#{position}/#{key}") # TODO: pass hint
        end
      else
        required_length = schema.min_properties || schema.max_properties || 0

        keys = (schema.properties || {}).keys
        keys -= (hint[:not_have_keys] || []) if hint

        object = keys.first(required_length).each.with_object({}) do |key, hash|
          hash[key] = _generate(schema.properties[key], hint: hint, position: "#{position}/#{key}") # TODO: pass hint
        end
      end

      # if length is not enough
      if schema.additional_properties === false
        (required_length - object.keys.length).times.each.with_object(object) do |i, hash|
          if schema.pattern_properties.empty?
            key = (schema.properties.keys - object.keys).first
            hash[key] = _generate(schema.properties[key], hint: hint, position: "#{position}/#{key}")
          else
            name = Pxeger.new(schema.pattern_properties.keys.first).generate
            hash[name] = _generate(schema.pattern_properties.values.first, hint: hint, position: "#{position}/#{name}")
          end
        end
      else
        # FIXME: key confilct with properties
        (required_length - object.keys.length).times.each.with_object(object) do |i, hash|
          hash[i.to_s] = i
        end
      end

      # consider dependency
      depended_keys = object.keys & schema.dependencies.keys

      # FIXME: circular dependency is not supported
      depended_keys.each.with_object(object) do |key, hash|
        dependency = schema.dependencies[key]

        if dependency.is_a?(JsonSchema::Schema)
          # too difficult we just merge
          hash.update(_generate(schema.dependencies[key], hint: nil, position: "#{position}/dependencies/#{key}"))
        else
          dependency.each do |additional_key|
            object[additional_key] = _generate(schema.properties[additional_key], hint: hint, position: "#{position}/dependencies/#{key}/#{additional_key}") unless object.has_key?(additional_key)
          end
        end
      end
    end

    def generate_by_enum(schema, hint: nil, position:)
      black_list = (hint ? hint[:not_be_values] : nil)

      if Configuration.logger
        Configuration.logger.info "generate by enum at #{position}"
        Configuration.logger.debug schema.inspect_schema
        Configuration.logger.debug "black list: #{black_list}" if black_list
      end

      if black_list
        (schema.enum - black_list).first
      else
        schema.enum.first
      end
    end

    def generate_by_type(schema, hint: nil, position:)
      if Configuration.logger
        Configuration.logger.info "generate by type at #{position}"
        Configuration.logger.debug schema.inspect_schema
      end

      # http://json-schema.org/latest/json-schema-core.html#anchor8
      # TODO: use include? than first
      case schema.type.first
      when "array"
        generate_for_array(schema, hint: hint, position: position)
      when "boolean"
        true
      when "integer", "number"
        generate_for_number(schema, hint: hint)
      when "null"
        nil
      when "object"
        # here comes object without properties
        generate_for_object(schema, hint: hint, position: position)
      when "string"
        generate_for_string(schema, hint: hint)
      else
        raise "unknown type for #{schema.inspect_schema}"
      end
    end

    def generate_for_array(schema, hint: nil, position:)
      # http://json-schema.org/latest/json-schema-validation.html#anchor36
      # additionalItems items maxItems minItems uniqueItems
      length = schema.min_items || 0

      # if "items" is not present, or its value is an object, validation of the instance always succeeds, regardless of the value of "additionalItems";
      # if the value of "additionalItems" is boolean value true or an object, validation of the instance always succeeds;
      item = if (schema.items.nil? || schema.items.is_a?(JsonSchema::Schema)) || ( schema.additional_items === true || schema.additional_items.is_a?(JsonSchema::Schema))
        length.times.map.with_index {|i| i }
      else # in case schema.items is array and schema.additional_items is true
        # if the value of "additionalItems" is boolean value false and the value of "items" is an array
        # the instance is valid if its size is less than, or equal to, the size of "items".
        raise "#{position}: item length(#{schema.items.length} is shorter than minItems(#{schema.min_items}))" unless schema.items.length <= length

        # TODO: consider unique items
        length.times.map.with_index {|i| _generate(schema.items[i], position: position + "[#{i}]") }
      end
    end

    def generate_for_number(schema, hint: nil)
      # http://json-schema.org/latest/json-schema-validation.html#anchor13
      # TODO: use hint[:not_be_values]
      min = schema.min
      max = schema.max

      if schema.multiple_of
        min = (min + schema.multiple_of - min % schema.multiple_of) if min
        max = (max - max % schema.multiple_of) if max
      end

      delta = schema.multiple_of ? schema.multiple_of : 1

      # TODO: more sophisticated caluculation
      min, max = [ (min || (max ? max - delta * 2 : 0)), (max || (min ? min + delta * 2 : 0)) ]

      # to get average of min and max can avoid exclusive*
      if schema.type.first == "integer"
        (min / delta + max / delta) / 2 * delta
      else
        (min + max) / 2.0
      end
    end

    def generate_for_string(schema, hint: nil)
      # http://json-schema.org/latest/json-schema-validation.html#anchor25
      # TODO: use hint[:not_be_values]
      # TODO: support format
      if schema.pattern
        Pxeger.new(schema.pattern).generate
      else
        length = schema.min_length || 0
        "a" * length
      end
    end
  end
end
