#if defined HAVE_CONFIG_H
#include "config.h"
#endif

#include "abi_common.h"

module m_vdw_xdm
 implicit none

 private

 public :: vdw_xdm

contains

  subroutine vdw_xdm(e_vdw_xdm)
    use defs_basis, only: dp
    implicit none

    real(dp),intent(out) :: e_vdw_xdm

    e_vdw_xdm = 0._dp

  end subroutine vdw_xdm

end module m_vdw_xdm
