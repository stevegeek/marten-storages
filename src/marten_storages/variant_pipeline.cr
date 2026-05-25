module MartenStorages
  # Libvips-driven resize pipeline. Pure-functional: takes an input
  # path + spec, writes a resized image to an output path. No DB.
  # `Service` calls this and turns the output into a sibling Attachment
  # row.
  #
  # Spec shape:
  #
  #   VariantPipeline::Spec.new(max_dimension: 1500)
  #   VariantPipeline::Spec.new(max_dimension: 600, format: "png")
  #
  # `max_dimension` is the only resize knob right now — matches
  # Writebook's original needs (cover thumbnail + picture large).
  # `format` is optional per-spec and overrides the configuration-level
  # `default_variant_format` for this variant only. Extend with
  # `quality:`, `crop:` etc. as needs arise.
  #
  # NamedTuple → Struct (review §19): the previous NamedTuple alias
  # forced every call site to spell every key and made adding fields a
  # breaking change. The Struct keeps construction kwarg-shaped while
  # letting us add optional fields without breaking callers. For
  # back-compat, `Spec.from(...)` accepts the legacy
  # `{max_dimension: N}` NamedTuple shape and is wired into
  # `Service.attach` overloads so existing call sites that pass a
  # `Hash(String, NamedTuple(max_dimension: Int32))` keep working.
  module VariantPipeline
    extend self

    # A variant resize specification. Constructed via kwargs:
    #
    #   VariantPipeline::Spec.new(max_dimension: 1500)
    #   VariantPipeline::Spec.new(max_dimension: 600, format: "png")
    struct Spec
      getter max_dimension : Int32
      # Per-variant output format override (e.g. "jpg", "png", "webp").
      # When `nil`, `Service` falls back to
      # `MartenStorages.configuration.default_variant_format`.
      getter format : String?

      def initialize(*, @max_dimension : Int32, @format : String? = nil)
      end

      # Back-compat constructor: accept the legacy
      # `{max_dimension: Int32}` NamedTuple literal shape so existing
      # `variants: {"large" => {max_dimension: 1500}}` call sites keep
      # working without changes.
      def self.from(tuple : NamedTuple(max_dimension: Int32)) : Spec
        new(max_dimension: tuple[:max_dimension])
      end

      def self.from(tuple : NamedTuple(max_dimension: Int32, format: String)) : Spec
        new(max_dimension: tuple[:max_dimension], format: tuple[:format])
      end

      def self.from(spec : Spec) : Spec
        spec
      end
    end

    # Resize the image at `source_path` according to `spec`. Returns the
    # path of the written variant file (caller is responsible for
    # cleanup). Raises `Vips::VipsException` if the source isn't a
    # vips-readable image; the caller (Service) catches that and skips
    # variant generation.
    def resize(source_path : String, spec : Spec, format : String = "jpg") : String
      image = ::Vips::Image.new_from_file(source_path)
      max_dim = spec.max_dimension
      scale = Math.min(max_dim.to_f / image.width, max_dim.to_f / image.height)
      resized = scale < 1.0 ? image.resize(scale) : image

      variant_path = "#{source_path}.variant.#{format}"
      resized.write_to_file(variant_path)
      variant_path
    end

    # Back-compat overload: accept the legacy NamedTuple `Spec` shape
    # (a `{max_dimension: Int32}` literal) and route through the Struct
    # form. See `Spec.from`.
    def resize(source_path : String, spec : NamedTuple(max_dimension: Int32), format : String = "jpg") : String
      resize(source_path, Spec.from(spec), format: format)
    end
  end
end
