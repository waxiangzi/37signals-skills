class Post < ApplicationRecord
  has_many :comments, dependent: :destroy
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings

  validates :title, presence: true

  scope :published, -> { where.not(published_at: nil) }

  def tag_names
    tags.order(:name).pluck(:name).join(", ")
  end

  def tag_names=(value)
    names = value.to_s.split(",").map(&:strip).reject(&:blank?).uniq
    self.tags = names.map { |name| Tag.find_or_create_by!(name: name) }
  end
end
