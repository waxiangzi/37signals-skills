module PostsHelper
  def post_excerpt(post, length: 120)
    truncate(strip_tags(post.body.to_s), length: length)
  end
end
