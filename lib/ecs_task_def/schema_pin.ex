defmodule EcsTaskDef.SchemaPin do
  @moduledoc """
  Single source of truth for the pinned awslabs amazon-ecs-intellisense-schema
  commit. `mix ecs.regen_schema` downloads from this SHA; the CLI displays it.
  Bumping the pin is an explicit edit of @sha followed by `mix ecs.regen_schema`.
  """

  @sha "39fae90314c74f897ba2a74549898542735e3628"

  def sha, do: @sha
  def short_sha, do: String.slice(@sha, 0, 7)

  def raw_url do
    "https://raw.githubusercontent.com/awslabs/amazon-ecs-intellisense-schema/#{@sha}/src/model/schema/schema.json"
  end

  def schema_path, do: Path.join(:code.priv_dir(:ecs_task_def), "schema.json")
end
