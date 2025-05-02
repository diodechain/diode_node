defmodule Diode.Version do
  @patches Mix.Project.config()[:version_patches]
  @description Mix.Project.config()[:version_description]
  @version Mix.Project.config()[:version]
  def patches() do
    @patches
  end

  def description() do
    String.trim(@description)
  end

  def version() do
    @version
  end
end
