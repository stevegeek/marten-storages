module MartenStorages
  # Module-level configuration. Currently exposes a registry of named
  # variant specs (so apps can declare a "thumbnail" or "large" set of
  # resize options once and reuse them across attach call sites) plus
  # the default variant output format.
  #
  #   MartenStorages.configure do |c|
  #     c.default_variant_format = "jpg"
  #     c.register_variant("thumbnail", max_dimension: 600)
  #     c.register_variant("large", max_dimension: 1500)
  #   end
  #
  # Variant specs are *opt-in*. The Service.attach call site can pass
  # `variants: {"large" => VariantPipeline::Spec.new(max_dimension: 1500)}`
  # directly without ever touching the registry — the registry is just
  # sugar for naming a spec once and reusing it.
  class Configuration
    # Output format for resized variants. `"jpg"` (default) routes
    # through vips' `write_to_file` with a `.jpg` extension; other
    # values must be extensions vips can write (e.g. `"png"`, `"webp"`).
    # Per-spec `format:` overrides this on a per-variant basis (see
    # `VariantPipeline::Spec#format`).
    property default_variant_format : String = "jpg"

    # Map of variant-kind name → spec. See `VariantPipeline::Spec` for
    # the spec shape. Populated via `register_variant`.
    getter registered_variants : Hash(String, VariantPipeline::Spec) = {} of String => VariantPipeline::Spec

    # Register a named variant spec.
    #
    # **Boot-time only** (review §9): `Hash#[]=` is not safe under
    # concurrent fiber mutation, so call from a single boot fiber inside
    # `MartenStorages.configure { ... }` and never mutate the registry
    # while request fibers are reading it. Re-registering the same
    # `kind` *raises* (review §13) so a typo or accidental double
    # registration is surfaced loudly instead of silently last-write-wins.
    def register_variant(kind : String, max_dimension : Int32, format : String? = nil) : Nil
      if @registered_variants.has_key?(kind)
        raise ArgumentError.new("variant '#{kind}' is already registered")
      end
      @registered_variants[kind] = VariantPipeline::Spec.new(max_dimension: max_dimension, format: format)
    end

    def lookup_variant(kind : String) : VariantPipeline::Spec?
      @registered_variants[kind]?
    end
  end

  # Class-level configuration store with a defensive initialization
  # mutex (review §20). Crystal's class-var initialisation is
  # technically thread-safe at module load time, but lazy-initializing
  # via `||=` in a class method is *not* — the Mutex below makes the
  # first-touch race explicitly safe. In practice `configure { ... }`
  # runs once from the boot fiber, but the cost of an uncontended
  # mutex acquire per `configuration` call is negligible.
  @@configuration : Configuration? = nil
  @@configuration_mutex = Mutex.new

  def self.configuration : Configuration
    if cfg = @@configuration
      return cfg
    end
    @@configuration_mutex.synchronize do
      @@configuration ||= Configuration.new
    end
    # After the synchronize block `@@configuration` is non-nil — but
    # rebind via a local so the compiler narrows the type (and ameba's
    # `Lint/NotNil` stays happy).
    case cfg = @@configuration
    in Configuration
      cfg
    in Nil
      raise "unreachable: configuration mutex set @@configuration"
    end
  end

  def self.configure(&block : Configuration ->) : Nil
    block.call(configuration)
  end

  # Reset to defaults — convenient for specs.
  def self.reset_configuration! : Nil
    @@configuration_mutex.synchronize do
      @@configuration = Configuration.new
    end
  end
end
