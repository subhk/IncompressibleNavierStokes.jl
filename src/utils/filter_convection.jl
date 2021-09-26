"""
    filter_convection(u, diff_matrix, bc, α)

Construct filter for convective terms
"""
function u_filtered = filter_convection(u, diff_matrix, bc, alfa)
    u_filtered = u + α*(diff_matrix*u + bc);
end