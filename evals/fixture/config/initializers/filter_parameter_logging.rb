Rails.application.configure do
  config.filter_parameters += [ :password ]
end
