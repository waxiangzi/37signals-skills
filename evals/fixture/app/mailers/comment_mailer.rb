class CommentMailer < ApplicationMailer
  def new_comment(comment)
    @comment = comment
    mail(to: "author@example.com", subject: "新评论")
  end
end
