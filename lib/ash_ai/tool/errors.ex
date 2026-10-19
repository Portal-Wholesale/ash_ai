# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Tool.Errors do
  @moduledoc """
  Formats Ash errors into human-readable text for tool responses.

  As the MCP specification dated 2025-06-18, tool execution errors should be
  returned as successful responses with `isError: true` and error details in
  the content array
  """

  require Logger

  @doc """
  Formats an Ash error into a mcp protocol compatible structure for tool error responses.

  `error_formatter` optionally overrides the text for individual errors. It is
  a one-arity function or a `{module, function, extra_args}` tuple, called with
  each underlying Ash error. Returning a string uses that text verbatim for the
  error; returning `nil` keeps the default `AshAi.ToToolError` text.
  """
  def format(error, error_formatter \\ nil) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map_join("\n", &format_with(&1, error_formatter))
    |> case do
      "" -> "Tool execution failed"
      text -> text
    end
  end

  defp format_with(error, nil), do: format_single_error(error)

  defp format_with(error, error_formatter) do
    case apply_formatter(error_formatter, error) do
      text when is_binary(text) ->
        text

      nil ->
        format_single_error(error)

      other ->
        raise ArgumentError,
              "error_formatter must return a string or nil, got: #{inspect(other)}"
    end
  end

  defp apply_formatter(formatter, error) when is_function(formatter, 1), do: formatter.(error)

  defp apply_formatter({module, function, args}, error)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: apply(module, function, [error | args])

  defp apply_formatter(other, _error) do
    raise ArgumentError,
          "error_formatter must be a one-arity function or {module, function, args}, got: #{inspect(other)}"
  end

  defp format_single_error(%{fields: fields} = error) when is_list(fields) and fields != [] do
    Enum.map_join(fields, "\n", fn field ->
      error |> Map.put(:fields, nil) |> Map.put(:field, field) |> format_single_error()
    end)
  end

  defp format_single_error(error) do
    msg =
      if AshAi.ToToolError.impl_for(error) do
        AshAi.ToToolError.to_tool_error(error)
      else
        Logger.warning("""
        AshAi.ToToolError not implemented for #{inspect(error.__struct__)}, returning a generic error message.

        #{Exception.format(:error, error)}\
        """)

        "unexpected error occurred"
      end

    case {Map.get(error, :path, []), Map.get(error, :field)} do
      {_, nil} -> msg
      {[], field} -> "#{field}: #{msg}"
      {path, field} -> "#{Enum.join(path ++ [field], ".")}: #{msg}"
    end
  end
end
