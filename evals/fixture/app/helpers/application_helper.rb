module ApplicationHelper
  def page_title(title = nil)
    [title, "Blog"].compact.join(" | ")
  end
end
