!!****m* ABINIT/m_vdw_xdm
!! NAME
!!  m_vdw_xdm
!!
!! FUNCTION
!!
!! COPYRIGHT
!!  Copyright (C) 2008-2021 ABINIT group (MT)
!!  This file is distributed under the terms of the
!!  GNU General Public License, see ~abinit/COPYING
!!  or http://www.gnu.org/copyleft/gpl.txt .
!!
!! PARENTS
!!
!! CHILDREN
!!
!! SOURCE

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
