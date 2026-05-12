# Host-defined Attachment row model. Owns the polymorphic `to:` list
# (compile-time fixed in Marten). Mirrors the shape `Service.attach`
# expects: name, file, variant_of, variation_kind, content_type, byte_size.
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

  def original?
    variant_of_id.nil?
  end

  def variant?
    !original?
  end
end
