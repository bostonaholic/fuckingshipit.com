helpers do
  def production?
    ENV["RACK_ENV"] == "production"
  end
end
