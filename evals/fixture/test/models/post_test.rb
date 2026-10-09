require "test_helper"

class PostTest < ActiveSupport::TestCase
  test "title is required" do
    assert_not Post.new(title: "").valid?
  end
end
