class Document < Marten::Model
  include ::MartenStorages::Attachable

  field :id, :big_int, primary_key: true, auto: true
  field :title, :string, max_size: 255, blank: false, null: false

  attachment_model DocumentAttachment
end
