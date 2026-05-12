module MartenStorages
  # Libvips-driven resize pipeline. Pure-functional: takes an input
  # path + spec, writes a resized image to an output path. No DB.
  # `Service` calls this and turns the output into a sibling Attachment
  # row.
  #
  # Spec shape:
  #
  #   {max_dimension: 1500}  # scale-to-fit; longest edge becomes 1500px
  #
  # `max_dimension` is the only knob right now — matches Writebook's
  # original needs (cover thumbnail + picture large). Extend with
  # `quality:`, `crop:`, `format:` etc. as needs arise.
  module VariantPipeline
    extend self

    alias Spec = NamedTuple(max_dimension: Int32)

    # Resize the image at `source_path` according to `spec`. Returns the
    # path of the written variant file (caller is responsible for
    # cleanup). Raises if the source isn't a vips-readable image; the
    # caller (Service) catches this and skips variant generation.
    def resize(source_path : String, spec : Spec, format : String = "jpg") : String
      image = ::Vips::Image.new_from_file(source_path)
      max_dim = spec[:max_dimension]
      scale = Math.min(max_dim.to_f / image.width, max_dim.to_f / image.height)
      resized = scale < 1.0 ? image.resize(scale) : image

      variant_path = "#{source_path}.variant.#{format}"
      resized.write_to_file(variant_path)
      variant_path
    end
  end
end
