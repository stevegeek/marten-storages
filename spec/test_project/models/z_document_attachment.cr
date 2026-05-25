# Host-defined Attachment row model. Owns the polymorphic `to:` list
# (compile-time fixed in Marten). Mirrors the shape `Service.attach`
# expects: name, file, variant_of, variation_kind, content_type, byte_size.
#
# Filename note (review §15): the `z_` prefix is *load-order plumbing*.
# `spec_helper.cr` requires `./test_project/models/**`, which resolves
# files alphabetically; this file references `Document` and
# `OtherDocument` in its polymorphic `to: [...]` list and would fail to
# compile if it loaded before them. The leading `z_` forces it to load
# last. If you rename it, also rename the require glob or accept the
# compile error.
class DocumentAttachment < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :record, :polymorphic, to: [Document, OtherDocument], related: :attachments
  field :name, :string, max_size: 64, blank: false, null: false
  field :file, :file, blank: false, null: false, upload_to: "attachments"
  field :variant_of, :many_to_one, to: DocumentAttachment, related: :variants, blank: true, null: true, on_delete: :cascade
  field :variation_kind, :string, max_size: 64, blank: true, null: true
  field :content_type, :string, max_size: 128, blank: true, null: true
  field :byte_size, :big_int, blank: true, null: true

  with_timestamp_fields

  # Test-only toggle used by spec/marten_storages_spec.cr to simulate a
  # non-vips, non-NotFoundError exception raised *inside*
  # `compute_and_save_variant`'s begin block (review STR-N1). When set
  # to `true`, the `before_save` callback below raises a `RuntimeError`
  # whenever a variant row is about to be saved — exercising the narrow
  # rescue's "let it through" path. Defaults to `false`; the spec flips
  # it on per-example and resets it in an `ensure`.
  class_property raise_on_variant_save : Bool = false

  before_save :maybe_raise_on_variant_save

  def original?
    variant_of_id.nil?
  end

  def variant?
    !original?
  end

  private def maybe_raise_on_variant_save : Nil
    return unless self.class.raise_on_variant_save
    return if variation_kind.nil?
    raise RuntimeError.new("simulated non-vips failure inside compute_and_save_variant")
  end
end
