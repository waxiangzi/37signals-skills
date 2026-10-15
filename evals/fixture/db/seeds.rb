Post.find_or_create_by!(title: "第一篇") do |post|
  post.body = "正文"
  post.published_at = Time.current
end
