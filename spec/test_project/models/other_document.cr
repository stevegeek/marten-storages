# Second polymorphic target so the polymorphic field's `to:` list has
# more than one entry (Marten compile-time requirement).
class OtherDocument < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :title, :string, max_size: 255, blank: false, null: false
end
