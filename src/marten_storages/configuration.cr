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
  # `variants: {"large" => {max_dimension: 1500}}` directly without ever
  # touching the registry — the registry is just sugar for naming a spec
  # once and reusing it.
  class Configuration
    # Output format for resized variants. `"jpg"` (default) routes
    # through vips' `write_to_file` with a `.jpg` extension; other
    # values must be extensions vips can write (e.g. `"png"`, `"webp"`).
    property default_variant_format : String = "jpg"

    # Map of variant-kind name → spec. See `VariantPipeline::Spec` for
    # the spec shape. Populated via `register_variant`.
    getter registered_variants : Hash(String, VariantPipeline::Spec) = {} of String => VariantPipeline::Spec

    def register_variant(kind : String, max_dimension : Int32) : Nil
      @registered_variants[kind] = {max_dimension: max_dimension}
    end

    def lookup_variant(kind : String) : VariantPipeline::Spec?
      @registered_variants[kind]?
    end
  end

  @@configuration : Configuration = Configuration.new

  def self.configuration : Configuration
    @@configuration
  end

  def self.configure(&block : Configuration ->) : Nil
    block.call(@@configuration)
  end

  # Reset to defaults — convenient for specs.
  def self.reset_configuration! : Nil
    @@configuration = Configuration.new
  end
end
