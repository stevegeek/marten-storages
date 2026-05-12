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
      spec.not_nil![:max_dimension].should eq 600
    end

    it "returns nil for unknown variant kinds" do
      MartenStorages.configuration.lookup_variant("absent").should be_nil
    end
  end

  describe MartenStorages::VariantPipeline do
    it "resizes a source image to fit within max_dimension" do
      src = SpecHelpers.make_test_jpeg(width: 1000, height: 500)
      out_path = MartenStorages::VariantPipeline.resize(src, {max_dimension: 200}, format: "jpg")
      ::File.exists?(out_path).should be_true
      img = ::Vips::Image.new_from_file(out_path)
      img.width.should be <= 200
      img.height.should be <= 200
      ::File.delete?(out_path)
    end
  end
end
