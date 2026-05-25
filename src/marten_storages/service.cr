module MartenStorages
  # Module-level helpers for attaching files to records via a host-defined
  # polymorphic `Attachment` model. Replaces the Active-Storage-style
  # `has_one_attached` / `has_many_attached` macros.
  #
  # The host owns the concrete Attachment model class (because Marten's
  # polymorphic `to:` list is compile-time fixed); the service takes it
  # as a `model:` keyword argument so the same shard can work against any
  # app's concrete table.
  #
  # Required fields on the host's Attachment model:
  #
  #   field :id, :big_int, primary_key: true, auto: true
  #   field :record, :polymorphic, to: [...host targets...]
  #   field :name, :string
  #   field :file, :file
  #   field :variant_of, :many_to_one, to: <self>, blank: true, null: true
  #   field :variation_kind, :string, blank: true, null: true
  #   field :content_type, :string, blank: true, null: true
  #   field :byte_size, :big_int, blank: true, null: true
  #
  # Basic upload:
  #
  #   MartenStorages::Service.attach(
  #     model: ::Books::Attachment,
  #     record: book, name: "cover", uploaded_file: uploaded,
  #   )
  #
  # With variants (pre-computed at upload time via crystal-vips):
  #
  #   MartenStorages::Service.attach(
  #     model: ::Books::Attachment,
  #     record: picture, name: "image", uploaded_file: uploaded,
  #     variants: {"large" => {max_dimension: 1500}},
  #   )
  module Service
    extend self

    alias VariantSpec = VariantPipeline::Spec

    # Attach a file to a record. Returns the saved Attachment row.
    # If variants are provided, additionally creates one Attachment row
    # per variant kind, each pointing at the original via `variant_of`.
    def attach(
      model : T.class,
      record : ::Marten::DB::Model,
      name : ::String,
      uploaded_file : ::Marten::HTTP::UploadedFile,
      variants : ::Hash(::String, VariantSpec) = ({} of ::String => VariantSpec),
    ) : T forall T
      original = model.new(
        name: name,
        content_type: nil,
        byte_size: uploaded_file.size.to_i64,
      )
      original.record = record
      original.file = uploaded_file
      original.save!

      variants.each do |kind, spec|
        compute_and_save_variant(model, original, kind, spec)
      end

      original
    end

    # Resolve a single attachment for a record + name (e.g. Book cover).
    # Returns the most recently created original (non-variant).
    def find_one(model : T.class, record : ::Marten::DB::Model, name : ::String) : T? forall T
      model
        .filter(record_type: record.class.name, record_id: record.pk)
        .filter(name: name)
        .filter(variant_of_id: nil)
        .order("-created_at")
        .first
    end

    # Resolve every original attachment for a record + name (oldest first),
    # ignoring variant rows.
    def find_many(model : T.class, record : ::Marten::DB::Model, name : ::String) : ::Array(T) forall T
      model
        .filter(record_type: record.class.name, record_id: record.pk)
        .filter(name: name)
        .filter(variant_of_id: nil)
        .order(:created_at)
        .to_a
    end

    # Look up a variant row for a given original Attachment + variation_kind.
    def variant_of(model : T.class, original : T, kind : ::String) : T? forall T
      model
        .filter(variant_of_id: original.pk)
        .filter(variation_kind: kind)
        .first
    end

    # Pipe the original through `VariantPipeline.resize` (libvips) and save
    # a new Attachment row pointing at the original. Falls back to a no-op
    # if the original isn't a vips-readable image. Any other error
    # (DB connection lost, disk full, unique-constraint violation,
    # a bug in this method) propagates to the caller.
    private def compute_and_save_variant(
      model : T.class,
      original : T,
      kind : ::String,
      spec : VariantSpec,
    ) : ::Nil forall T
      original_file = original.file
      return if original_file.name.nil?

      source_name = original_file.name.not_nil!
      temp_path = ::File.tempname("variant_#{kind}_", ::File.extname(source_name))
      variant_path : ::String? = nil

      begin
        # original_file.open delegates to the storage backend and returns an IO.
        # No block form — close it manually.
        source_io = original_file.open
        begin
          ::File.open(temp_path, "wb") { |f| ::IO.copy(source_io, f) }
        ensure
          source_io.close
        end

        format = MartenStorages.configuration.default_variant_format
        variant_path = VariantPipeline.resize(temp_path, spec, format: format)

        base = ::File.basename(source_name, ::File.extname(source_name))
        variant_filename = "#{base}_#{kind}.#{format}"
        content_type = format == "jpg" || format == "jpeg" ? "image/jpeg" : "image/#{format}"

        content_disposition = "form-data; name=\"file\"; filename=\"#{variant_filename}\""
        part_headers = ::HTTP::Headers{
          "Content-Disposition" => content_disposition,
          "Content-Type"        => content_type,
        }

        ::File.open(variant_path, "rb") do |variant_io|
          part = ::HTTP::FormData::Part.new(headers: part_headers, body: variant_io)
          uploaded = ::Marten::HTTP::UploadedFile.new(part)

          variant = model.new(
            name: original.name,
            variation_kind: kind,
            content_type: content_type,
            byte_size: ::File.size(variant_path).to_i64,
          )
          variant.record = original.record!
          variant.variant_of = original
          variant.file = uploaded
          variant.save!
        end
      rescue ex : ::Vips::VipsException | ::File::NotFoundError
        # Original isn't a vips-readable image (e.g. PDF, plain text) or
        # the underlying storage file vanished between save! and our open
        # (already-deleted race). Skip variant generation silently. The
        # original is still saved.
        ::Marten::Log.warn { "Skipping variant '#{kind}' for attachment #{original.pk}: #{ex.message}" }
      ensure
        # Always clean up tempfiles on success *and* failure — otherwise
        # `Dir.tempdir` fills up over time on a busy box (review §2).
        ::File.delete?(temp_path)
        if vp = variant_path
          ::File.delete?(vp)
        end
      end
    end
  end
end
