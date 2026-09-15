module SimpleDrive
  # Keeps credentials out of the usual ways an object gets printed: #inspect
  # (the console's echo, p, pp, logs, exception messages), YAML (the console's
  # y, to_yaml) and JSON (as_json, to_json). An including class defines
  # #filtered_attributes, passing each secret through #filtered.
  module FilteredOutput
    def inspect
      "#<#{self.class.name} #{filtered_attributes.map { |name, value| "#{name}=#{value.inspect}" }.join(' ')}>"
    end

    def encode_with(coder)
      filtered_attributes.each { |name, value| coder[name.to_s] = value }
    end

    def as_json(options = nil)
      filtered_attributes.as_json(options)
    end

    private

    # As in Active Record's filtered #inspect, a secret that is not set still
    # shows as nil, so a missing credential stays visible.
    def filtered(value)
      value.nil? ? nil : "[FILTERED]"
    end
  end
end
