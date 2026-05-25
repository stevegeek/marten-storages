require "./spec_helper"

describe MartenStorages do
  describe MartenStorages::Service do
    describe ".attach" do
      it "creates an Attachment row pointing at the host record" do
        doc = Document.create!(title: "fresh")
        path = SpecHelpers.make_test_jpeg
        att = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "cover",
            uploaded_file: uploaded,
          )
        end

        att.should be_a(DocumentAttachment)
        att.record_type.should eq "Document"
        att.record_id.should eq doc.pk
        att.name.should eq "cover"
        att.variant_of_id.should be_nil
        att.byte_size.should_not be_nil
        att.original?.should be_true
        att.persisted?.should be_true
      end

      it "saves the underlying file to media storage" do
        doc = Document.create!(title: "fresh")
        path = SpecHelpers.make_test_jpeg
        att = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "cover",
            uploaded_file: uploaded,
          )
        end

        att.file.name.should_not be_nil
        on_disk = ::File.join(MEDIA_ROOT, att.file.name.not_nil!)
        ::File.exists?(on_disk).should be_true
      end

      it "persists the supplied content_type on the original (review §3)" do
        doc = Document.create!(title: "with-content-type")
        path = SpecHelpers.make_test_jpeg
        att = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "cover",
            uploaded_file: uploaded,
            content_type: "image/jpeg",
          )
        end

        att.content_type.should eq "image/jpeg"
      end

      it "leaves content_type nil on the original when not supplied (back-compat)" do
        doc = Document.create!(title: "no-content-type")
        path = SpecHelpers.make_test_jpeg
        att = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "cover",
            uploaded_file: uploaded,
          )
        end

        att.content_type.should be_nil
      end

      it "produces variant rows for each kind in `variants:`" do
        doc = Document.create!(title: "with variants")
        path = SpecHelpers.make_test_jpeg(width: 800, height: 600)

        original = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "image",
            uploaded_file: uploaded,
            variants: {"thumbnail" => {max_dimension: 200}},
          )
        end

        variants = DocumentAttachment.filter(variant_of_id: original.pk).to_a
        variants.size.should eq 1
        v = variants.first
        v.variation_kind.should eq "thumbnail"
        v.variant_of_id.should eq original.pk
        v.record_id.should eq doc.pk
        v.record_type.should eq "Document"
        v.variant?.should be_true
      end

      it "accepts the Struct-form VariantPipeline::Spec directly" do
        doc = Document.create!(title: "struct-spec")
        path = SpecHelpers.make_test_jpeg(width: 800, height: 600)
        spec_hash = {
          "thumbnail" => MartenStorages::VariantPipeline::Spec.new(max_dimension: 200),
        }

        original = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "image",
            uploaded_file: uploaded,
            variants: spec_hash,
          )
        end

        DocumentAttachment.filter(variant_of_id: original.pk).count.should eq 1
      end

      it "honours the per-spec `format:` override (review §14)" do
        doc = Document.create!(title: "per-spec-format")
        path = SpecHelpers.make_test_jpeg(width: 800, height: 600)
        spec_hash = {
          "thumbnail" => MartenStorages::VariantPipeline::Spec.new(max_dimension: 200, format: "png"),
        }

        original = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "image",
            uploaded_file: uploaded,
            variants: spec_hash,
          )
        end

        variant = DocumentAttachment.filter(variant_of_id: original.pk).first.not_nil!
        variant.content_type.should eq "image/png"
        variant.file.name.not_nil!.should end_with(".png")
      end

      it "supports multiple variants in a single attach call" do
        doc = Document.create!(title: "multi-variant")
        path = SpecHelpers.make_test_jpeg
        original = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "image",
            uploaded_file: uploaded,
            variants: {
              "thumbnail" => {max_dimension: 200},
              "large"     => {max_dimension: 400},
            },
          )
        end

        kinds = DocumentAttachment
          .filter(variant_of_id: original.pk)
          .order(:variation_kind)
          .to_a
          .map(&.variation_kind)
        kinds.should eq ["large", "thumbnail"]
      end

      it "skips variants silently when the original isn't vips-readable (review §1 / §22)" do
        doc = Document.create!(title: "non-image")
        path = SpecHelpers.make_test_non_image

        original = SpecHelpers.uploaded_file(path, content_type: "application/pdf") do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "doc",
            uploaded_file: uploaded,
            variants: {"thumbnail" => {max_dimension: 200}},
            content_type: "application/pdf",
          )
        end

        original.persisted?.should be_true
        original.content_type.should eq "application/pdf"
        DocumentAttachment.filter(variant_of_id: original.pk).count.should eq 0
      end

      it "raises ArgumentError when a variant `kind` contains path-traversal characters (review §4 / §22)" do
        doc = Document.create!(title: "bad-kind")
        path = SpecHelpers.make_test_jpeg

        ex = expect_raises(ArgumentError, /kind must match/) do
          SpecHelpers.uploaded_file(path) do |uploaded|
            MartenStorages::Service.attach(
              model: DocumentAttachment,
              record: doc,
              name: "image",
              uploaded_file: uploaded,
              variants: {"../../etc/cron.d/x" => {max_dimension: 200}},
            )
          end
        end
        ex.message.not_nil!.should contain("../../etc/cron.d/x")

        # Whole attach should have rolled back — no original either (review §7).
        DocumentAttachment.filter(record_type: "Document", record_id: doc.pk).count.should eq 0
      end

      it "raises ArgumentError when a variant `kind` contains a slash" do
        doc = Document.create!(title: "slash-kind")
        path = SpecHelpers.make_test_jpeg

        expect_raises(ArgumentError, /kind must match/) do
          SpecHelpers.uploaded_file(path) do |uploaded|
            MartenStorages::Service.attach(
              model: DocumentAttachment,
              record: doc,
              name: "image",
              uploaded_file: uploaded,
              variants: {"foo/bar" => {max_dimension: 200}},
            )
          end
        end
      end

      it "propagates non-vips errors (e.g. bad kind) instead of swallowing them as `not a vips image` (review §1)" do
        # Narrow rescue check: `kind`-validation raises `ArgumentError`,
        # which is not in the narrow `Vips::VipsException |
        # File::NotFoundError` rescue list — so it must propagate to the
        # caller instead of being logged-and-swallowed (the pre-§1
        # bare-rescue behaviour).
        doc = Document.create!(title: "bad-kind-propagates")
        path = SpecHelpers.make_test_jpeg

        expect_raises(ArgumentError, /kind must match/) do
          SpecHelpers.uploaded_file(path) do |uploaded|
            MartenStorages::Service.attach(
              model: DocumentAttachment,
              record: doc,
              name: "image",
              uploaded_file: uploaded,
              variants: {"bad/kind" => {max_dimension: 200}},
            )
          end
        end
      end

      it "cleans up tempfiles even when variant computation raises (review §2)" do
        doc = Document.create!(title: "cleanup-on-raise")
        path = SpecHelpers.make_test_non_image
        before = Dir.glob(::File.join(::Dir.tempdir, "variant_thumbnail_*")).size

        SpecHelpers.uploaded_file(path, content_type: "application/pdf") do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment,
            record: doc,
            name: "doc",
            uploaded_file: uploaded,
            variants: {"thumbnail" => {max_dimension: 200}},
            content_type: "application/pdf",
          )
        end

        # vips fails on the non-image, the rescue handles it — and the
        # ensure cleans up `temp_path` despite the rescue. Net tempfile
        # count for our prefix should not grow.
        after = Dir.glob(::File.join(::Dir.tempdir, "variant_thumbnail_*")).size
        after.should eq before
      end
    end

    describe ".find_one" do
      it "returns the most recently created original (skipping variants)" do
        doc = Document.create!(title: "lookup")
        path = SpecHelpers.make_test_jpeg

        SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment, record: doc, name: "cover", uploaded_file: uploaded,
            variants: {"thumbnail" => {max_dimension: 200}},
          )
        end

        found = MartenStorages::Service.find_one(model: DocumentAttachment, record: doc, name: "cover")
        found.should_not be_nil
        found.not_nil!.variant_of_id.should be_nil
        found.not_nil!.name.should eq "cover"
      end

      it "returns nil when no attachment matches" do
        doc = Document.create!(title: "absent")
        found = MartenStorages::Service.find_one(model: DocumentAttachment, record: doc, name: "cover")
        found.should be_nil
      end
    end

    describe ".variant_of" do
      it "returns the variant row for a given (original, kind) pair" do
        doc = Document.create!(title: "variantof")
        path = SpecHelpers.make_test_jpeg

        original = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment, record: doc, name: "image", uploaded_file: uploaded,
            variants: {"thumbnail" => {max_dimension: 200}},
          )
        end

        v = MartenStorages::Service.variant_of(model: DocumentAttachment, original: original, kind: "thumbnail")
        v.should_not be_nil
        v.not_nil!.variation_kind.should eq "thumbnail"
      end

      it "returns nil when no variant of that kind exists (review §22)" do
        doc = Document.create!(title: "variant-absent")
        path = SpecHelpers.make_test_jpeg

        original = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment, record: doc, name: "image", uploaded_file: uploaded,
            variants: {"thumbnail" => {max_dimension: 200}},
          )
        end

        MartenStorages::Service.variant_of(model: DocumentAttachment, original: original, kind: "absent")
          .should be_nil
      end
    end

    describe "cascading delete" do
      it "removes variant rows when the parent original is deleted (on_delete cascade)" do
        doc = Document.create!(title: "cascade")
        path = SpecHelpers.make_test_jpeg

        original = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment, record: doc, name: "image", uploaded_file: uploaded,
            variants: {"thumbnail" => {max_dimension: 200}},
          )
        end
        DocumentAttachment.filter(variant_of_id: original.pk).count.should eq 1

        original.delete
        DocumentAttachment.filter(variant_of_id: original.pk).count.should eq 0
      end

      # Known limitation lock (review §22): deleting the Attachment row
      # cascades the *rows* but does not currently delete the underlying
      # on-disk media file. If/when the shard wires a `:on_delete`
      # storage cleanup, flip this assertion to `should be_false`.
      it "does NOT currently remove on-disk media when the row is deleted (documented limitation)" do
        doc = Document.create!(title: "cascade-disk")
        path = SpecHelpers.make_test_jpeg

        original = SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment, record: doc, name: "image", uploaded_file: uploaded,
          )
        end
        on_disk = ::File.join(MEDIA_ROOT, original.file.name.not_nil!)
        ::File.exists?(on_disk).should be_true

        original.delete

        ::File.exists?(on_disk).should be_true
      end
    end
  end

  describe MartenStorages::Attachable do
    it "adds attachment_for(name) returning the latest original" do
      doc = Document.create!(title: "attachable")
      path = SpecHelpers.make_test_jpeg
      SpecHelpers.uploaded_file(path) do |uploaded|
        MartenStorages::Service.attach(
          model: DocumentAttachment, record: doc, name: "cover", uploaded_file: uploaded,
        )
      end

      doc.attachment_for("cover").should_not be_nil
      doc.attachment_for("absent").should be_nil
    end

    it "adds attachments_for(name) returning all originals oldest-first" do
      doc = Document.create!(title: "many")
      path = SpecHelpers.make_test_jpeg
      2.times do
        SpecHelpers.uploaded_file(path) do |uploaded|
          MartenStorages::Service.attach(
            model: DocumentAttachment, record: doc, name: "uploads", uploaded_file: uploaded,
          )
        end
      end

      doc.attachments_for("uploads").size.should eq 2
    end

    it "adds variants_of(attachment, kind) for the variant row lookup" do
      doc = Document.create!(title: "variants_of")
      path = SpecHelpers.make_test_jpeg
      original = SpecHelpers.uploaded_file(path) do |uploaded|
        MartenStorages::Service.attach(
          model: DocumentAttachment, record: doc, name: "image", uploaded_file: uploaded,
          variants: {"thumbnail" => {max_dimension: 200}},
        )
      end

      v = doc.variants_of(original, "thumbnail")
      v.should_not be_nil
      v.not_nil!.variation_kind.should eq "thumbnail"
    end
  end

  describe MartenStorages::Configuration do
    it "registers a named variant spec" do
      MartenStorages.configure do |c|
        c.register_variant("thumbnail", max_dimension: 600)
      end

      spec = MartenStorages.configuration.lookup_variant("thumbnail")
      spec.should_not be_nil
      spec.not_nil!.max_dimension.should eq 600
      spec.not_nil!.format.should be_nil
    end

    it "accepts an optional per-variant format on registration (review §14)" do
      MartenStorages.configure do |c|
        c.register_variant("thumbnail", max_dimension: 600, format: "png")
      end

      MartenStorages.configuration.lookup_variant("thumbnail").not_nil!.format.should eq "png"
    end

    it "raises on duplicate variant registration (review §13)" do
      MartenStorages.configure do |c|
        c.register_variant("thumbnail", max_dimension: 600)
      end

      expect_raises(ArgumentError, /already registered/) do
        MartenStorages.configure do |c|
          c.register_variant("thumbnail", max_dimension: 800)
        end
      end
    end

    it "returns nil for unknown variant kinds" do
      MartenStorages.configuration.lookup_variant("absent").should be_nil
    end
  end

  describe MartenStorages::VariantPipeline do
    it "resizes a source image to fit within max_dimension" do
      src = SpecHelpers.make_test_jpeg(width: 1000, height: 500)
      out_path = MartenStorages::VariantPipeline.resize(
        src,
        MartenStorages::VariantPipeline::Spec.new(max_dimension: 200),
        format: "jpg",
      )
      ::File.exists?(out_path).should be_true
      img = ::Vips::Image.new_from_file(out_path)
      img.width.should be <= 200
      img.height.should be <= 200
      ::File.delete?(out_path)
    end

    it "accepts the legacy NamedTuple Spec shape for back-compat" do
      src = SpecHelpers.make_test_jpeg(width: 1000, height: 500)
      out_path = MartenStorages::VariantPipeline.resize(src, {max_dimension: 200}, format: "jpg")
      ::File.exists?(out_path).should be_true
      ::File.delete?(out_path)
    end
  end
end
