### ----------------------------------------------------------------------
###
### Copyright (c) 2013 - 2018 Lee Sylvester and Xirsys LLC <experts@xirsys.com>
###
### All rights reserved.
###
### XTurn is licensed by Xirsys under the Apache
### License, Version 2.0. (the "License");
###
### you may not use this file except in compliance with the License.
### You may obtain a copy of the License at
###
###      http://www.apache.org/licenses/LICENSE-2.0
###
### Unless required by applicable law or agreed to in writing, software
### distributed under the License is distributed on an "AS IS" BASIS,
### WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
### See the License for the specific language governing permissions and
### limitations under the License.
###
### See LICENSE for the full license text.
###
### ----------------------------------------------------------------------

defmodule Xirsys.XTurn.Supervisor do
  use Supervisor

  alias Xirsys.XTurn.{Server, Allocate}
  alias Xirsys.Sockets.Listener.{TCP, UDP}
  alias Xirsys.Sockets.SockSupervisor

  def start_link(listen, cb) do
    Supervisor.start_link(__MODULE__, [listen, cb])
  end

  def init([list, cb]) do
    listen = list

    listener_children =
      listen
      |> Enum.map(fn data ->
        start_listener(data, cb)
      end)

    # `{mod, arg}` passes a single start_link arg (same as deprecated `worker(mod, [arg])`).
    # Do not use `[Allocate.Client]` here — that would call `start_link([Allocate.Client])`.
    #
    # `Server` and `SockSupervisor`: use explicit `start_link/0` MFA (see `child_spec_start_link_0/1`).
    #
    # TCP/UDP listeners: legacy `worker(UDP, [cb, ip, port, ssl])` was `apply(UDP, :start_link, ...)`
    # with four args. `{UDP, [cb, ip, port, ssl]}` wrongly calls `start_link([cb,ip,port,ssl])`.
    # Use `start: {mod, :start_link, [cb, ip, port, ssl]}`.
    Supervisor.init(
      [
        child_spec_start_link_0(Server),
        {Allocate.Supervisor, Allocate.Client},
        child_spec_start_link_0(SockSupervisor)
      ] ++ listener_children,
      strategy: :one_for_one
    )
  end

  defp start_listener({type, ipStr, port}, cb) do
    {:ok, ip} = :inet_parse.address(ipStr)
    mod = listener(type)

    Supervisor.child_spec(mod,
      id: {:xturn_listener, type, ip, port, :plain},
      start: {mod, :start_link, [cb, ip, port, false]}
    )
  end

  defp start_listener({type, ipStr, port, secure}, cb) do
    {:ok, ip} = :inet_parse.address(ipStr)
    mod = listener(type)

    Supervisor.child_spec(mod,
      id: {:xturn_listener, type, ip, port, secure},
      start: {mod, :start_link, [cb, ip, port, secure == :secure]}
    )
  end

  defp listener(:tcp), do: TCP
  defp listener(:udp), do: UDP

  defp child_spec_start_link_0(mod) do
    Supervisor.child_spec(mod, start: {mod, :start_link, []})
  end
end
