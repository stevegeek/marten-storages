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
  #
  # Perf note (review §5): on a filesystem media backend each variant
  # currently lands on disk four times (original upload tempfile,
  # `temp_path` source copy here, libvips `variant_path` output,
  # storage backend `write` of the final variant). The redundant
  # `temp_path` copy can be eliminated for filesystem backends by
  # reading the original's path directly when the storage backend
  # `responds_to?(:path)`; for cloud backends the copy stays
  # necessary. Deferred — fine for Writebook-scale uploads (~MB), and
  # the cloud-backend story is a separate piece of work.
  #
  # Fiber-safety note (review §6): `source_io = original_file.open`
  # returns a fresh `File` for the filesystem backend, which is
  # non-blocking enough for the local case. If/when a cloud backend
  # whose `open` streams an HTTP body lands, `::IO.copy(source_io, ...)`
  # below will block the fiber for the duration of the download — at
  # that point this method should run on a worker fiber or use
  # streaming/multipart copies.
  module Service
    extend self

    # Regex used to validate variant `kind` names — the value flows into
    # `File.tempname`'s prefix and the on-disk variant filename, so we
    # restrict it to a safe charset (review §4).
    private KIND_NAME_RE = /\A[A-Za-z0-9_-]+\z/

    alias VariantSpec = VariantPipeline::Spec

    # Attach a file to a record. Returns the saved Attachment row.
    # If variants are provided, additionally creates one Attachment row
    # per variant kind, each pointing at the original via `variant_of`.
    #
    # `content_type:` is the MIME type to persist on the original row
    # (typically pulled from the `HTTP::FormData::Part`'s `Content-Type`
    # header by the host handler). Defaults to `nil` for back-compat;
    # variants always compute their own content type from the configured
    # output format.
    #
    # The whole attach (original + every variant) is wrapped in a single
    # DB transaction so a mid-loop failure rolls back the original row
    # too (review §7). Variant files already written to media storage
    # before the failing variant are *not* rolled back by the DB
    # transaction — that's a known limitation tracked separately.
    def attach(
      model : T.class,
      record : ::Marten::DB::Model,
      name : ::String,
      uploaded_file : ::Marten::HTTP::UploadedFile,
      variants : ::Hash(::String, VariantSpec) = ({} of ::String => VariantSpec),
      content_type : ::String? = nil,
    ) : T forall T
      original : T? = nil
      ::Marten::DB::Connection.default.transaction do
        built = model.new(
          name: name,
          content_type: content_type,
          byte_size: uploaded_file.size.to_i64,
        )
        built.record = record
        built.file = uploaded_file
        built.save!

        variants.each do |kind, spec|
          compute_and_save_variant(model, built, kind, spec)
        end

        original = built
      end

      # `original` is non-nil iff the transaction block completed (i.e.
      # `save!` succeeded and no variant raised). Failures propagate out
      # of `transaction` directly, so a `nil` here is unreachable — but
      # match on the local to keep the compiler honest without
      # `not_nil!`.
      case saved = original
      in T
        saved
      in Nil
        raise "unreachable: attach transaction completed without setting original"
      end
    end

    # Back-compat overload: accept the legacy NamedTuple-shaped variants
    # hash (`{"thumbnail" => {max_dimension: 200}}`) and normalize each
    # spec to a `VariantSpec` Struct (review §19). Pre-existing call
    # sites that use NamedTuple literals keep working unchanged.
    def attach(
      model : T.class,
      record : ::Marten::DB::Model,
      name : ::String,
      uploaded_file : ::Marten::HTTP::UploadedFile,
      variants : ::Hash(::String, NamedTuple(max_dimension: Int32)),
      content_type : ::String? = nil,
    ) : T forall T
      normalized = variants.transform_values { |tuple| VariantSpec.from(tuple) }
      attach(
        model: model, record: record, name: name, uploaded_file: uploaded_file,
        variants: normalized, content_type: content_type,
      )
    end

    # Back-compat overload: accept the NamedTuple shape with an explicit
    # `format:` field (`{"thumbnail" => {max_dimension: 200, format: "webp"}}`)
    # so call sites that need per-variant format overrides can stay on
    # the literal NamedTuple form without dropping to the Struct API.
    def attach(
      model : T.class,
      record : ::Marten::DB::Model,
      name : ::String,
      uploaded_file : ::Marten::HTTP::UploadedFile,
      variants : ::Hash(::String, NamedTuple(max_dimension: Int32, format: String)),
      content_type : ::String? = nil,
    ) : T forall T
      normalized = variants.transform_values { |tuple| VariantSpec.from(tuple) }
      attach(
        model: model, record: record, name: name, uploaded_file: uploaded_file,
        variants: normalized, content_type: content_type,
      )
    end

    # Resolve a single attachment for a record + name (e.g. Book cover).
    # Returns the most recently created original (non-variant).
    #
    # Ordering uses the symbol-form `:created_at` (with `.reverse`)
    # everywhere in this module for consistency (review §16).
    def find_one(model : T.class, record : ::Marten::DB::Model, name : ::String) : T? forall T
      originals_query(model, record, name).order(:created_at).reverse.first
    end

    # Resolve every original attachment for a record + name (oldest first),
    # ignoring variant rows.
    def find_many(model : T.class, record : ::Marten::DB::Model, name : ::String) : ::Array(T) forall T
      originals_query(model, record, name).order(:created_at).to_a
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
      unless kind.matches?(KIND_NAME_RE)
        raise ArgumentError.new("kind must match /\\A[A-Za-z0-9_-]+\\z/, got: #{kind.inspect}")
      end

      original_file = original.file
      source_name = original_file.name
      return if source_name.nil?

      temp_path = ::File.tempname("variant_#{kind}_", ::File.extname(source_name))
      variant_path : ::String? = nil

      begin
        # original_file.open delegates to the storage backend and returns an IO.
        # No block form — close it manually.
        source_io = original_file.open
        begin
          ::File.open(temp_path, "wb") { |dest| ::IO.copy(source_io, dest) }
        ensure
          source_io.close
        end

        # Per-spec format override (review §14) wins over the
        # configuration-level default.
        format = spec.format || MartenStorages.configuration.default_variant_format
        variant_path = VariantPipeline.resize(temp_path, spec, format: format)

        base = ::File.basename(source_name, ::File.extname(source_name))
        variant_filename = "#{base}_#{kind}.#{format}"
        content_type = format == "jpg" || format == "jpeg" ? "image/jpeg" : "image/#{format}"

        content_disposition = "form-data; name=\"file\"; filename=\"#{variant_filename}\""
        part_headers = ::HTTP::Headers{
          "Content-Disposition" => content_disposition,
          "Content-Type"        => content_type,
        }

        # `byte_size` is read while `variant_path` is still open via the
        # block below (review §17). POSIX `stat(2)` on an open file is
        # safe; on Windows it would be platform-dependent. The save! call
        # also runs while the FD is open — peak FD usage during attach is
        # the storage handle + tempfile + variant file + UploadedFile
        # tempfile (~4 FDs per variant; review §18).
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
        ::Marten::Log.warn(exception: ex) { "Skipping variant '#{kind}' for attachment #{original.pk}" }
      ensure
        # Always clean up tempfiles on success *and* failure — otherwise
        # `Dir.tempdir` fills up over time on a busy box (review §2).
        ::File.delete?(temp_path)
        if vp = variant_path
          ::File.delete?(vp)
        end
      end
    end

    # Shared filter chain for "originals (non-variant) attached to this
    # record under this name". Kept private so `Service` is the single
    # source of truth (review §10/§11) — the `Attachable` mixin's
    # macro-generated query helpers mirror this shape for the host's
    # concrete Attachment class.
    private def originals_query(model : T.class, record : ::Marten::DB::Model, name : ::String) forall T
      model
        .filter(record_type: record.class.name, record_id: record.pk)
        .filter(name: name)
        .filter(variant_of_id: nil)
    end
  end
end
