!!****m* ABINIT/m_frohlichmodel
!! NAME
!!  m_frohlichmodel
!!
!! FUNCTION
!!  Compute ZPR, temperature-dependent electronic structure, and other properties
!!  using the Frohlich model
!!
!! COPYRIGHT
!!  Copyright (C) 2018-2021 ABINIT group (XG)
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

module m_frohlichmodel

 use defs_basis
 use m_abicore
 use m_errors
 use m_crystal
 use m_ebands
 use m_efmas_defs
 use m_ifc
 use m_dtset

 use m_fstrings,            only : sjoin, itoa
 use m_gaussian_quadrature, only : cgqf

 implicit none

 private

 public :: frohlichmodel

contains
!!***

!!****f* m_frohlichmodel/frohlichmodel
!! NAME
!!  frohlichmodel
!!
!! FUNCTION
!! Main routine to compute properties based on the Frohlich model
!!
!! INPUTS
!! cryst<crystal_t>=Structure defining the unit cell
!! dtset<dataset_type>=All input variables for this dataset.
!! efmasdeg(nkpt_rbz) <type(efmasdeg_type)>= information about the band degeneracy at each k point
!! efmasval(mband,nkpt_rbz) <type(efmasdeg_type)>= double tensor datastructure
!!   efmasval(:,:)%eig2_diag band curvature double tensor
!! ifc<ifc_type>=contains the dynamical matrix and the IFCs.
!!
!! PARENTS
!!      m_eph_driver
!!
!! CHILDREN
!!      cgqf,ifc%calcnwrite_nana_terms,zheev
!!
!! SOURCE

subroutine frohlichmodel(cryst, dtset, efmasdeg, efmasval, ifc)

!Arguments ------------------------------------
!scalars
 type(crystal_t),intent(in) :: cryst
 type(dataset_type),intent(in) :: dtset
 type(ifc_type),intent(in) :: ifc
!arrays
 type(efmasdeg_type), intent(in) :: efmasdeg(:)
 type(efmasval_type), intent(in) :: efmasval(:,:)

!Local variables ------------------------------
!scalars
 logical :: sign_warn
 integer :: deg_dim,iband,ideg,idir,ikpt,imode,info,ipar,iphi,iqdir,itheta
 integer :: jband,lwork,nphi,nqdir,ntheta
 real(dp) :: angle_phi,cosph,costh,sinph,sinth,weight,weight_phi
 real(dp) :: zpr_frohlich,zpr_q0_avg,zpr_q0_fact
 !character(len=500) :: msg
!arrays
 logical, allocatable :: saddle_warn(:), start_eigf3d_pos(:)
 logical :: lutt_found(3), lutt_warn(3)
 real(dp) :: kpt(3), lutt_params(3), lutt_unit_kdir(3,3)
 real(dp), allocatable :: eigenval(:), rwork(:), unit_qdir(:,:)
 real(dp), allocatable :: lutt_dij(:,:), lutt_eigenval(:,:)
 real(dp), allocatable :: m_avg(:), m_avg_frohlich(:)
 real(dp), allocatable :: gq_points_th(:),gq_weights_th(:)
 real(dp), allocatable :: gq_points_cosph(:),gq_points_sinph(:)
 real(dp), allocatable :: weight_qdir(:)
 real(dp), allocatable :: polarity_qdir(:,:,:)
 real(dp), allocatable :: proj_polarity_qdir(:,:)
 real(dp), allocatable :: zpr_q0_phononfactor_qdir(:)
 real(dp), allocatable :: frohlich_phononfactor_qdir(:)
 real(dp), allocatable :: phfrq_qdir(:,:)
 real(dp), allocatable :: dielt_qdir(:)
 real(dp), allocatable :: zpr_frohlich_avg(:)
 complex(dpc), allocatable :: eigenvec(:,:), work(:)
 complex(dpc), allocatable :: eig2_diag_cart(:,:,:,:)
 complex(dpc), allocatable :: f3d(:,:)

!************************************************************************

 !!! Initialization of integrals
 ntheta   = dtset%efmas_ntheta
 nphi     = 2*ntheta
 nqdir     = nphi*ntheta

 ABI_MALLOC(gq_points_th,(ntheta))
 ABI_MALLOC(gq_weights_th,(ntheta))
 ABI_MALLOC(gq_points_cosph,(nphi))
 ABI_MALLOC(gq_points_sinph,(nphi))

 ABI_MALLOC(unit_qdir,(3,nqdir))
 ABI_MALLOC(weight_qdir,(nqdir))

 call cgqf(ntheta,1,zero,zero,zero,pi,gq_points_th,gq_weights_th)
 weight_phi=two*pi/real(nphi,dp)
 do iphi=1,nphi
   angle_phi=weight_phi*(iphi-1)
   gq_points_cosph(iphi)=cos(angle_phi)
   gq_points_sinph(iphi)=sin(angle_phi)
 enddo
 nqdir=0
 do itheta=1,ntheta
   costh=cos(gq_points_th(itheta))
   sinth=sin(gq_points_th(itheta))
   weight=gq_weights_th(itheta)*weight_phi*sinth
   do iphi=1,nphi
     cosph=gq_points_cosph(iphi) ; sinph=gq_points_sinph(iphi)
     nqdir=nqdir+1

     unit_qdir(1,nqdir)=sinth*cosph
     unit_qdir(2,nqdir)=sinth*sinph
     unit_qdir(3,nqdir)=costh
     weight_qdir(nqdir)=weight

   enddo
 enddo

 ABI_FREE(gq_points_th)
 ABI_FREE(gq_weights_th)
 ABI_FREE(gq_points_cosph)
 ABI_FREE(gq_points_sinph)

 ABI_MALLOC(polarity_qdir,(3,3*cryst%natom,nqdir))
 ABI_MALLOC(proj_polarity_qdir,(3*cryst%natom,nqdir))
 ABI_MALLOC(zpr_q0_phononfactor_qdir,(nqdir))
 ABI_MALLOC(frohlich_phononfactor_qdir,(nqdir))
 ABI_MALLOC(phfrq_qdir,(3*cryst%natom,nqdir))
 ABI_MALLOC(dielt_qdir,(nqdir))

 !Compute phonon frequencies and mode-polarity for each qdir
 call ifc%calcnwrite_nana_terms(cryst, nqdir, unit_qdir, phfrq2l=phfrq_qdir, polarity2l=polarity_qdir)

 !Compute dielectric tensor for each qdir
 do iqdir=1,nqdir
   dielt_qdir(iqdir)=DOT_PRODUCT(unit_qdir(:,iqdir),MATMUL(ifc%dielt(:,:),unit_qdir(:,iqdir)))
 enddo

 !Compute projection of mode-polarity on qdir, and other derived quantities summed over phonon branches for each iqdir.
 !Note that acoustic modes are discarded (imode sum starts only from 4)
 zpr_q0_phononfactor_qdir=zero
 zpr_q0_avg=zero
 frohlich_phononfactor_qdir=zero
 do iqdir=1,nqdir
   do imode=4,3*cryst%natom
     proj_polarity_qdir(imode,iqdir)=DOT_PRODUCT(unit_qdir(:,iqdir),polarity_qdir(:,imode,iqdir))
     zpr_q0_phononfactor_qdir(iqdir)=zpr_q0_phononfactor_qdir(iqdir)+&
&      proj_polarity_qdir(imode,iqdir)**2 / phfrq_qdir(imode,iqdir) **2
     frohlich_phononfactor_qdir(iqdir)=frohlich_phononfactor_qdir(iqdir)+&
&      proj_polarity_qdir(imode,iqdir)**2 / phfrq_qdir(imode,iqdir) **(three*half)
   enddo
   zpr_q0_avg=zpr_q0_avg+&
&    weight_qdir(iqdir)*zpr_q0_phononfactor_qdir(iqdir)/dielt_qdir(iqdir)**2
 enddo
 zpr_q0_avg=zpr_q0_avg*quarter*piinv
 zpr_q0_fact=zpr_q0_avg*eight*pi*(three*quarter*piinv)**third*cryst%ucvol**(-four*third)

!DEBUG
! do iqdir=1,nqdir,513
!   write(std_out,'(a,3f8.4,3es12.4)')' unit_qdir,dielt_qdir,zpr_q0_phononfactor_qdir,frohlich_phononfactor=',&
!&    unit_qdir(:,iqdir),dielt_qdir(iqdir),zpr_q0_phononfactor_qdir(iqdir),frohlich_phononfactor_qdir(iqdir)
!   do imode=1,3*cryst%natom
!     write(std_out,'(a,i5,6es12.4)')'   imode,phfrq_qdir,phfrq(cmm1),polarity_qdir=',&
!&     imode,phfrq_qdir(imode,iqdir),phfrq_qdir(imode,iqdir)*Ha_cmm1,polarity_qdir(:,imode,iqdir),proj_polarity_qdir(imode,iqdir)
!   enddo
! enddo
! write(std_out,'(2a,3es12.4)')ch10,&
!& ' zpr_q0_avg, zpr_q0_fact, zpr_q0_fact (eV) =',zpr_q0_avg, zpr_q0_fact, zpr_q0_fact*Ha_eV
!ENDDEBUG

 write(ab_out,'(6a,f14.6,a,f14.6,a)') ch10,&
&  ' Rough correction to the ZPR, to take into account the missing q=0 piece using Frohlich model:',ch10,&
&  ' (+ for occupied states, - for unoccupied states) * zpr_q0_fact / (Nqpt_full_bz)**(1/3) ',ch10,&
&  ' where Nqpt_full_bz=number of q wavevectors in full BZ, and zpr_q0_fact=',zpr_q0_fact,' Ha=',zpr_q0_fact*Ha_eV,' eV'

 !Compute effective masses, and integrate the Frohlich model
 do ikpt=1,dtset%nkpt

   kpt(:)=dtset%kptns(:,ikpt)
   do ideg=efmasdeg(ikpt)%deg_range(1),efmasdeg(ikpt)%deg_range(2)

     deg_dim    = efmasdeg(ikpt)%degs_bounds(2,ideg) - efmasdeg(ikpt)%degs_bounds(1,ideg) + 1

     ABI_MALLOC(eig2_diag_cart,(3,3,deg_dim,deg_dim))

     !Convert eig2_diag to cartesian coordinates
     do iband=1,deg_dim
        do jband=1,deg_dim
          eig2_diag_cart(:,:,iband,jband)=efmasval(ideg,ikpt)%eig2_diag(:,:,iband,jband)
          eig2_diag_cart(:,:,iband,jband)=&
&           matmul(matmul(cryst%rprimd,eig2_diag_cart(:,:,iband,jband)),transpose(cryst%rprimd))/two_pi**2
        enddo
     enddo

     ABI_MALLOC(f3d,(deg_dim,deg_dim))
     ABI_MALLOC(m_avg,(deg_dim))
     ABI_MALLOC(m_avg_frohlich,(deg_dim))
     ABI_MALLOC(zpr_frohlich_avg,(deg_dim))
     ABI_MALLOC(eigenval,(deg_dim))
     ABI_MALLOC(saddle_warn,(deg_dim))
     ABI_MALLOC(start_eigf3d_pos,(deg_dim))

     m_avg=zero
     m_avg_frohlich=zero
     saddle_warn=.false.

     !Initializations for the diagonalization routine
     if(deg_dim>1)then

       ABI_MALLOC(eigenvec,(deg_dim,deg_dim))
       lwork=-1
       ABI_MALLOC(rwork,(3*deg_dim-2))
       ABI_MALLOC(work,(1))
       call zheev('V','U',deg_dim,eigenvec,deg_dim,eigenval,work,lwork,rwork,info)
       lwork=int(work(1))
       ABI_FREE(work)
       ABI_MALLOC(work,(lwork))

     endif

     !Compute the Luttinger parameters for the cubic case (deg_dim=3)
     if(deg_dim==3) then

       ABI_MALLOC(lutt_eigenval, (3,deg_dim))
       ABI_MALLOC(lutt_dij, (deg_dim, deg_dim))

       !Define unit_kdir for Luttinger parameters
       lutt_unit_kdir(:,1) = (/1,0,0/)
       lutt_unit_kdir(:,2) = 1/sqrt(2.0)*(/1,1,0/)
       lutt_unit_kdir(:,3) = 1/sqrt(3.0)*(/1,1,1/)

       !Degeneracy problems warning
       lutt_warn=(/.false.,.false.,.false./)

       !Inverse effective mass tensor eigenvalues in lutt_unit_kdir directions
       do idir=1,3
         do iband=1,deg_dim
           do jband=1,deg_dim
             lutt_dij(iband,jband)=&
&             DOT_PRODUCT(lutt_unit_kdir(:,idir),MATMUL(eig2_diag_cart(:,:,iband,jband),lutt_unit_kdir(:,idir)))
           enddo
         enddo

         eigenvec=lutt_dij ; lutt_eigenval(idir,:)=zero
         work=zero     ; rwork=zero
         call zheev('V','U',deg_dim,eigenvec,deg_dim,lutt_eigenval(idir,:),work,lwork,rwork,info)
         ABI_CHECK(info == 0, sjoin("zheev returned info:", itoa(info)))
       enddo

       !Check degeneracies in (100) direction, and evaluate A and B.
       !Eigenvalues are 2*A (d=1), 2*B (d=2)
       if(abs(lutt_eigenval(1,2)-lutt_eigenval(1,3))<tol5) then
         lutt_params(2)=0.5*((lutt_eigenval(1,2)+lutt_eigenval(1,3))/2)
         lutt_params(1)=0.5*lutt_eigenval(1,1)
       else if(abs(lutt_eigenval(1,2)-lutt_eigenval(1,1))<tol5) then
         lutt_params(2)=0.5*((lutt_eigenval(1,2)+lutt_eigenval(1,1))/2)
         lutt_params(1)=0.5*lutt_eigenval(1,3)
       else
         lutt_warn(1)=.true.
       endif

       !Check degeneracies in (111) direction and evaluate C
       !Eigenvalues are 2/3*(A+2B-C) (d=2), 2/3*(A+2B+2C) (d=1)
       if(abs(lutt_eigenval(3,2)-lutt_eigenval(3,3))<tol5) then
         lutt_params(3)=lutt_params(1)+2*lutt_params(2)-1.5*(0.5*(lutt_eigenval(3,2)+lutt_eigenval(3,3)))
       else if(abs(lutt_eigenval(3,2)-lutt_eigenval(3,1))<tol5) then
         lutt_params(3)=lutt_params(1)+2*lutt_params(2)-1.5*(0.5*(lutt_eigenval(3,2)+lutt_eigenval(3,1)))
       else
         lutt_warn(2)=.true.
       endif

       !Verify that the (110) direction eigenvalues are coherent with Luttinger parameters
       !Eigenvalues are 2B, A+B-C, A+B+C
       lutt_found=(/.false.,.false.,.false./)
       do ipar=1,deg_dim
         if(abs(lutt_eigenval(2,ipar)-2*lutt_params(2))<tol4) then
           lutt_found(1)=.true.
         else if(abs(lutt_eigenval(2,ipar)-(lutt_params(1)+lutt_params(2)-lutt_params(3)))<tol4) then
           lutt_found(2)=.true.
         else if(abs(lutt_eigenval(2,ipar)-(lutt_params(1)+lutt_params(2)+lutt_params(3)))<tol4) then
           lutt_found(3)=.true.
         endif
       enddo

       if(.not. (all(lutt_found))) then
         lutt_warn(3)=.true.
       endif

       ABI_FREE(lutt_eigenval)
       ABI_FREE(lutt_dij)

     endif !Luttinger parameters

     !Perform the integral over the sphere
     zpr_frohlich_avg=zero
     do iqdir=1,nqdir
       do iband=1,deg_dim
         do jband=1,deg_dim
           f3d(iband,jband)=DOT_PRODUCT(unit_qdir(:,iqdir),MATMUL(eig2_diag_cart(:,:,iband,jband),unit_qdir(:,iqdir)))
         enddo
       enddo

       if(deg_dim==1)then
         eigenval(1)=f3d(1,1)
       else
         eigenvec = f3d ; eigenval = zero
         work=zero      ; rwork=zero
         call zheev('V','U',deg_dim,eigenvec,deg_dim,eigenval,work,lwork,rwork,info)
         ABI_CHECK(info == 0, sjoin("zheev returned info:", itoa(info)))
       endif

       m_avg = m_avg + weight_qdir(iqdir)*eigenval
       m_avg_frohlich = m_avg_frohlich + weight_qdir(iqdir)/(abs(eigenval))**half
       zpr_frohlich_avg = zpr_frohlich_avg + &
&        weight_qdir(iqdir) * frohlich_phononfactor_qdir(iqdir)/((abs(eigenval))**half *dielt_qdir(iqdir)**2)

       if(iqdir==1) start_eigf3d_pos = (eigenval > 0)

       do iband=1,deg_dim
         if(start_eigf3d_pos(iband) .neqv. (eigenval(iband)>0)) then
           saddle_warn(iband)=.true.
         end if
       end do

     enddo

     if(deg_dim>1)then
       ABI_FREE(eigenvec)
       ABI_FREE(rwork)
       ABI_FREE(work)
     endif

     m_avg = quarter*piinv*m_avg
     m_avg = one/m_avg

     m_avg_frohlich = quarter*piinv * m_avg_frohlich
     m_avg_frohlich = m_avg_frohlich**2

     zpr_frohlich_avg = quarter*piinv * zpr_frohlich_avg

     if(deg_dim==1)then
       write(ab_out,'(2a,3(f6.3,a),i5)')ch10,&
&        ' - At k-point (',kpt(1),',',kpt(2),',',kpt(3),'), band ',&
&        efmasdeg(ikpt)%degs_bounds(1,ideg)
     else
       write(ab_out,'(2a,3(f6.3,a),i5,a,i5)')ch10,&
&        ' - At k-point (',kpt(1),',',kpt(2),',',kpt(3),'), bands ',&
&        efmasdeg(ikpt)%degs_bounds(1,ideg),' through ',efmasdeg(ikpt)%degs_bounds(2,ideg)
     endif

     !Print the Luttinger for the cubic case (deg_dim=3)
     if(deg_dim==3) then
       if (.not. (any(saddle_warn))) then
         if(any(lutt_warn)) then
           ! Warn for degeneracy breaking in inverse effective mass tensor eigenvalues
           write(ab_out, '(2a)') ch10, ' Luttinger parameters could not be determined:'
           if (lutt_warn(1)) then
             write(ab_out, '(a)') '     Predicted degeneracies for deg_dim = 3 are not met for (100) direction.'
           endif
           if (lutt_warn(2)) then
             write(ab_out, '(a)') '     Predicted degeneracies for deg_dim = 3 are not met for (111) direction.'
           endif
           if (lutt_warn(3)) then
             write(ab_out, '(a)') '     Predicted inverse effective mass tensor eigenvalues for direction (110) are not met.'
           endif
           write(ab_out, '(a)') ch10
         else
           write(ab_out, '(a,3f14.6)') ' Luttinger parameters (A, B, C) [at. units]: ',lutt_params(:)
         endif
       endif
     endif

     sign_warn=.false.
     do iband=1,deg_dim
       if(saddle_warn(iband)) then
         write(ab_out,'(a,i5,a)') ' Band ',efmasdeg(ikpt)%degs_bounds(1,ideg)+iband-1,&
&          ' SADDLE POINT - Frohlich effective mass and ZPR cannot be defined. '
         sign_warn=.true.
       else
         m_avg_frohlich(iband) = DSIGN(m_avg_frohlich(iband),m_avg(iband))
         zpr_frohlich_avg(iband) = -DSIGN(zpr_frohlich_avg(iband),m_avg(iband))
         write(ab_out,'(a,i5,a,f14.10)') &
&          ' Band ',efmasdeg(ikpt)%degs_bounds(1,ideg)+iband-1,&
&          ' Angular average effective mass for Frohlich model (<m**0.5>)**2= ',m_avg_frohlich(iband)
       endif
       if(start_eigf3d_pos(iband) .neqv. start_eigf3d_pos(1))then
         sign_warn=.true.
       endif
     enddo

     if(sign_warn .eqv. .false.)then
       zpr_frohlich = four*pi* two**(-half) * (sum(zpr_frohlich_avg(1:deg_dim))/deg_dim) / cryst%ucvol
       write(ab_out,'(2a)')&
&       ' Angular and band average effective mass and ZPR for Frohlich model.'
       write(ab_out,'(a,es16.6)') &
&       ' Value of     (<<m**0.5>>)**2 = ',(sum(abs(m_avg_frohlich(1:deg_dim))**0.5)/deg_dim)**2
       write(ab_out,'(a,es16.6)') &
&       ' Absolute Value of <<m**0.5>> = ', sum(abs(m_avg_frohlich(1:deg_dim))**0.5)/deg_dim
       write(ab_out,'(a,es16.6,a,es16.6,a)') &
&       ' ZPR from Frohlich model      = ',zpr_frohlich,' Ha=',zpr_frohlich*Ha_eV,' eV'
     else
       write(ab_out,'(a)')&
&        ' Angular and band average effective mass for Frohlich model cannot be defined because of a sign problem.'
     endif

     ABI_FREE(eig2_diag_cart)
     ABI_FREE(f3d)
     ABI_FREE(m_avg)
     ABI_FREE(m_avg_frohlich)
     ABI_FREE(zpr_frohlich_avg)
     ABI_FREE(eigenval)
     ABI_FREE(saddle_warn)
     ABI_FREE(start_eigf3d_pos)

   enddo ! ideg
 enddo ! ikpt

 ABI_FREE(unit_qdir)
 ABI_FREE(weight_qdir)
 ABI_FREE(polarity_qdir)
 ABI_FREE(proj_polarity_qdir)
 ABI_FREE(phfrq_qdir)
 ABI_FREE(dielt_qdir)
 ABI_FREE(zpr_q0_phononfactor_qdir)
 ABI_FREE(frohlich_phononfactor_qdir)

 end subroutine frohlichmodel

end module m_frohlichmodel
!!***
