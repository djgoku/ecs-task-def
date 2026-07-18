defmodule EcsTaskDef.Output do
  @moduledoc """
  Atomic output writes: temp file in the destination directory, then rename.
  An existing destination is only replaced by the final rename; on any failure
  the temp file is removed and the destination is left untouched.
  """

  def write(path, iodata) do
    dir = Path.dirname(path)

    tmp =
      Path.join(dir, ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}")

    with :ok <- File.write(tmp, iodata),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
