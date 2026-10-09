class CommentNotificationJob < ApplicationJob
  retry_on Net::ReadTimeout, wait: 10.seconds, attempts: 5

  def perform(comment)
    CommentMailer.new_comment(comment).deliver_now
    comment.update!(notified_at: Time.current)
  end
end
