[
  # Dialyzer collapses success typing for `handle_ticket/2` to ticketv1-only when both
  # the legacy "ticket" and "ticketv2" RPC paths call the same defp, then flags the
  # ticketv2 call site as invalid_call. Both shapes are handled at runtime.
  ~r/lib\/network\/edge_v2\.ex:227:call/
]
