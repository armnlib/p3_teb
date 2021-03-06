!-------------------------------------- LICENCE BEGIN ------------------------------------
!Environment Canada - Atmospheric Science and Technology License/Disclaimer,
!                     version 3; Last Modified: May 7, 2008.
!This is free but copyrighted software; you can use/redistribute/modify it under the terms
!of the Environment Canada - Atmospheric Science and Technology License/Disclaimer
!version 3 or (at your option) any later version that should be found at:
!http://collaboration.cmc.ec.gc.ca/science/rpn.comm/license.html
!
!This software is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
!without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
!See the above mentioned License/Disclaimer for more details.
!You should have received a copy of the License/Disclaimer along with this software;
!if not, you can write to: EC-RPN COMM Group, 2121 TransCanada, suite 500, Dorval (Quebec),
!CANADA, H9P 1J3; or send e-mail to service.rpn@ec.gc.ca
!-------------------------------------- LICENCE END --------------------------------------

subroutine condensation(d    , dsiz , f    , fsiz , v   , vsiz, &
                        t0   , q0   , qc0  , ilab , beta, ccfcp,&
                        zcte , zste , zcqe , zsqe , &
                        zcqce, zsqce, zcqre, zsqre, &
                        dt   , ni   , n1    , nk, &
                        kount, trnch, icpu)
   use phy_options
   use my_dmom_mod,  only: mydmom_main
   use mp_my2_mod,   only: mp_my2_main
   use module_mp_p3, only: mp_p3_wrapper_gem,n_qiType
   use phybus

   implicit none
#include <arch_specific.hf>
   !@Object Interface to convection/condensation
   !@Arguments
   !          - Input -
   ! dsiz     dimension of dbus
   ! fsiz     dimension of fbus
   ! vsiz     dimension of vbus
   ! dt       timestep (sec.)
   ! ni       horizontal running length
   ! nk       vertical dimension
   ! kount    timestep number
   ! trnch    slice number
   ! icpu     cpu number executing slice "trnch"
   !
   !          - Input/Output -
   ! d        dynamics input field
   ! f        historic variables for the physics
   ! v        physics tendencies and other output fields from the physics
   !
   !          - Output -
   ! t0       initial temperature at t+dT
   ! q0       initial humidity humidity  at t+dT
   ! qc0      initial total condensate mixing ratio at t+dT
   ! ilab     flag array: an indication of convective activity from Kuo schemes
   ! beta     estimated averaged cloud fraction growth rate for kuostd
   ! ccfcp    cloud fractional coverage area for kfc and bechtold
   ! zcte     convective temperature tendency
   ! zste     stratiform temperature tendency
   ! zcqe     convective humidity tendency
   ! zsqe     stratiform humidity tendency
   ! zcqce    convective total condensate tendency
   ! zsqce    stratiform total condensate tendency
   ! zcqre    convective rain mixing ratio tendency
   ! zsqre    stratiform rain mixing ratio tendency

   integer :: fsiz,vsiz,dsiz,ni,n1,nk,kount,trnch,icpu
   real    :: dt
   integer,dimension(ni,nk) :: ilab
   real,   dimension(ni)    :: beta
   real,   dimension(ni,nk) :: t0,q0,qc0,zcte, zste, zcqe, zsqe
   real,   dimension(ni,nk) :: zcqce, zsqce, zcqre, zsqre, ccfcp
   real,   target           :: f(fsiz), v(vsiz), d(dsiz)

   !@Author L.Spacek, November 2011
   !@Revisions
   ! 001      new arguments in call to mydmom_main
   ! 002      PV-nov2014: fix communication between deep convection and MY_Dm

   include "thermoconsts.inc"
   include "nocld.cdk"

   logical,save :: dbgcond = .false.
   logical :: lkfbe
   integer :: i,k
   real :: cdt1

   real, dimension(ni)      :: tlcr,tscr
   real, dimension(ni,nk)   :: zfm,zfm1,zcqer,zcqcer,zcter,press,tdmask2d,iwc_total,lqip,lqrp,lqgp,lqnp,geop

   logical, parameter               :: nk_BOTTOM = .true.   !(.T. for nk at bottom)
   integer, parameter               :: n_diag_2d = 20       !number of diagnostic 2D fields  (diag_2d)
   integer, parameter               :: n_diag_3d = 20       !number of diagnostic 3D fields  (SS)
   integer, parameter               :: aeroact   = 1        !default aerosol activation    (mp_my2, mp_p3)
   integer                          :: istat1               !error status (for mp_p3)
   real, dimension(ni,n_diag_2d)    :: diag_2d              !diagnostic 2D fields
   real, dimension(ni,nk,n_diag_3d) :: diag_3d              !diagnostic 3D fields
   real, dimension(ni,nk)           :: Naero                !aerosol number concentration  (mp_my2, mp_p3)
   real, dimension(ni,nk,n_qiType)  :: qi_type              !diagnostic ice particle type  (mp_p3)

   !# cnd_ptr_as.cdk has ptr association, should be included after declarations
   real, pointer, dimension(:) :: a_h_cb, a_h_m2, a_h_ml, a_h_sn, a_tls, &
        a_tls_rn1, a_tls_rn2, a_tls_fr1, a_tls_fr2, a_tss, a_tss_pe1, &
        a_tss_pe2, a_tss_pe2l, a_tss_sn1, a_tss_sn2, a_tss_sn3, a_tss_snd, &
        a_zec, psm, psp, ztdmask, ztlc, ztsc, &
        a_d2d01,a_d2d02,a_d2d03,a_d2d04,a_d2d05,a_d2d06,a_d2d07,a_d2d08,a_d2d09,a_d2d10, &
        a_d2d11,a_d2d12,a_d2d13,a_d2d14,a_d2d15,a_d2d16,a_d2d17,a_d2d18,a_d2d19,a_d2d20

   real, pointer, dimension(:,:) :: a_effradc, a_effradi1, a_effradi2, a_effradi3, &
        a_effradi4, a_fxp, qti1p, qti1m, qmi1p, nti1p, &
        bmi1p, qti2p, qti2m, qmi2p, nti2p, bmi2p, qti3p, qti3m, qmi3p, nti3p, bmi3p, qti4p, &
        qti4m, qmi4p, nti4p, bmi4p, a_dm_c, a_dm_r, a_dm_i, a_dm_s, a_dm_g, a_dm_h, &
        a_slw, a_ss01, a_ss02, a_ss03, a_ss04, a_ss05, a_ss06, a_ss07, a_ss08, &
        a_ss09, a_ss10, a_ss11, a_ss12, a_ss13, a_ss14, a_ss15, a_ss16, &
        a_ss17, a_ss18, a_ss19, a_ss20, a_vis, a_vis1, a_vis2, a_vis3, a_zet, &
        ncm, ncp, nctend, ngm, ngp, ngtend, nhm, nhp, nhtend, nim, nip, &
        nitend, nnm, nnp, nntend, nrm, nrp, nrtend, qcm, qcp, qctend, qgm, &
        qgp, qgtend, qhm, qhp, qhtend, qim, qip, qitend, qnm, qnp, qntend, &
        qrm, qrp, qrtend, qqm, qqp, qtend, sigma, ttend, &
        ttm, ttp, ww, zcqe_, zcte_, zfbl, zfdc, zgztherm, zhushal, zprcten, &
        zqtde, zsqe_, zste_, ztqcx, ztshal, zzcqcem, zzcqem, zzctem, zzsqcem, &
        zzsqem, zzstem, a_qi_1, a_qi_2, a_qi_3, a_qi_4, a_qi_5, a_qi_6


   include "cnd_ptr_as.cdk"

   cdt1   = factdt * dt
   tdmask2d(:,:) = spread(ztdmask, dim=2, ncopies=nk)
   tdmask2d(:,:) = tdmask2d(:,:) * delt
   lkfbe  = any(convec == (/'BECHTOLD','KFC     '/))

   select case(stcond)
   case('CONDS')

      !# scheme simplifie
      zfdc(:,:) = zfbl(:,:)
      call conds(zste,zsqe,f(tls),f(tss), &
           f(fbl),ttp,qqp,psp,v(kcl), &
           sigma, cdt1, ni, ni, nk, &
           dbgcond, satuco)

   case('NEWSUND')

      !# sundqvist (deuxieme version) :
      call skocon3(zste, zsqe, zsqce, f(tlc), f(tsc), f(tls), &
           f(tss), f(fxp), f(fdc), ttp, ttm, qqp, &
           qqm, f(tsurf), qcp, qcm, psp, &
           psm, ilab, sigma, ni, nk, &
           factdt, dt, satuco, convec, v(rnflx), v(snoflx))

   case('CONSUN')

      tlcr = 0.
      tscr = 0.
      zcter = 0.
      zcqer = 0.
      zcqcer = 0.
      if (convec=='KUOSTD') then
         !# transvider les tendances convectives pour kuostd
         !# par contre, on ne veut pas d'interaction
         !# entre les schemas kfc et consun.
         zcter = zcte
         zcqer = zcqe
      endif

      zfm1 = qcm
      zfm  = qcp
      call consun1(zste , zsqe , zsqce , f(tls), f(tss), f(fxp), &
           zcter, zcqer, zcqcer, tlcr  , tscr  , f(fdc), &
           ttp    , ttm   , qqp     , qqm    , zfm   , zfm1  , &
           psp , psm  , ilab  , beta  , sigma, cdt1  , &
           v(rnflx), v(snoflx), v(f12) , v(fevp)  , &
           f(fice), v(clr), v(cls), ni , nk)
      !# transvider les tendances convectives et les taux
      !# des precipitations pour kuostd
      if (convec == 'KUOSTD') then
         ztsc(:) =  tscr(:)
         ztlc(:) =  tlcr(:)
         !# transvider les tendances de t et hu ainsi que
         !# la fraction nuageuse.
         !# amalgamer les champs de sortie de kuosym et de fcp.
         zcqce = zcqcer
         zcte  = zcter
         zcqe  = zcqer
      else if (lkfbe) then
         zfdc=ccfcp
      endif

   case('MP_MY2_OLD')

      !# Milbrandt-Yau 2-moment microphysics (MY2; v2.18.5)
      geop = zgztherm*grav
      call mydmom_main(ww,&
           ttp,qqp,qcp,qrp,qip,qnp,qgp,qhp,ncp,nrp,nip,nnp,ngp,nhp,psp, &
           ttm,qqm,qcm,qrm,qim,qnm,qgm,qhm,ncm,nrm,nim,nnm,ngm,nhm,psm,sigma,&
           a_tls_rn1, a_tls_rn2, a_tls_fr1, a_tls_fr2,&
           a_tss_sn1, a_tss_sn2, a_tss_sn3,&
           a_tss_pe1, a_tss_pe2, a_tss_pe2l, a_tss_snd,geop,&
           zste, zsqe, zsqce,zsqre,&
           qitend, qntend, qgtend, qhtend, nctend,&
           nrtend, nitend, nntend, ngtend, nhtend,&
           cdt1, ni, n1, nk, trnch, kount, my_ccntype, &
           my_diagon, my_sedion, my_warmon, &
           my_rainon, my_iceon,  my_snowon, my_initn,&
           my_dblmom_c, my_dblmom_r, my_dblmom_i, &
           my_dblmom_s, my_dblmom_g, my_dblmom_h,&
           a_dm_c, a_dm_r, a_dm_i, a_dm_s, a_dm_g, a_dm_h,&
           a_zet,  a_zec,  a_slw,  a_vis,  a_vis1, a_vis2, a_vis3,&
           a_h_cb, a_h_ml, a_h_m2, a_h_sn, &
           a_ss01, a_ss02, a_ss03, a_ss04, a_ss05, a_ss06, a_ss07,&
           a_ss08, a_ss09, a_ss10, a_ss11, a_ss12, a_ss13, a_ss14,&
           a_ss15, a_ss16, a_ss17, a_ss18, a_ss19, a_ss20,        &
           my_tc3comp,  &
           v(rnflx),v(snoflx),v(f12),v(fevp),v(clr),v(cls),a_fxp,a_effradc,&
           a_effradi1, a_effradi2, a_effradi3, a_effradi4)

   case('MP_MY2')

! !       !# Milbrandt-Yau 2-moment microphysics (MY2; v2.25.2)
! !       call mp_my2_main(ww,ttp,qqp,qcp,qrp,qip,qnp,qgp,qhp,ncp,nrp,nip,nnp,ngp,nhp,             &
! !             psp, sigma, a_tls_rn1, a_tls_rn2, a_tls_fr1, a_tls_fr2, a_tss_sn1, a_tss_sn2,      &
! !             a_tss_sn3, a_tss_pe1, a_tss_pe2, a_tss_pe2l, a_tss_snd,dt, ni, nk, 1, kount,       &
! !             my_ccntype, my_diagon, my_sedion, my_warmon, my_rainon, my_iceon,                  &
! !             my_snowon, a_dm_c,a_dm_r,a_dm_i,a_dm_s,a_dm_g,a_dm_h, a_zet, a_zec,diag_3d,        &
! !             a_effradc, a_effradi1, a_effradi2, a_effradi3, a_effradi4, a_fxp, nk_BOTTOM)

      Naero = 0.  !(not used on this version)
      !# Milbrandt-Yau 2-moment microphysics (MY2; v3.2.0)
      call mp_my2_main(ww,ttp,qqp,qcp,qrp,qip,qnp,qgp,qhp,ncp,nrp,nip,nnp,ngp,nhp,bmi1p,Naero,   &
            psp, sigma, a_tls_rn1, a_tls_rn2, a_tls_fr1, a_tls_fr2, a_tss_sn1, a_tss_sn2,        &
            a_tss_sn3, a_tss_pe1, a_tss_pe2, a_tss_pe2l, a_tss_snd,dt, ni, nk, 1, kount,aeroact, &
            my_ccntype, my_diagon, my_sedion, my_warmon, my_rainon, my_iceon,                    &
            my_snowon, a_dm_c,a_dm_r,a_dm_i,a_dm_s,a_dm_g,a_dm_h, a_zet, a_zec,diag_3d,          &
            a_effradc, a_effradi1, a_effradi2, a_effradi3, a_effradi4, a_fxp, nk_BOTTOM)

      !-- temporary:  (until RN/FR separation gets removed in MY2)
      a_tls_rn1 = a_tls_rn1 + a_tls_fr1
      a_tls_rn2 = a_tls_rn2 + a_tls_fr2
      a_tls_fr1 = 0.
      a_tls_fr2 = 0.

      a_ss01 = diag_3d(:,:,1);   a_ss11 = diag_3d(:,:, 8);   a_ss16 = diag_3d(:,:,15)
      a_ss02 = diag_3d(:,:,2);   a_ss12 = diag_3d(:,:, 9);   a_ss17 = diag_3d(:,:,16)
      a_ss03 = diag_3d(:,:,3);   a_ss08 = diag_3d(:,:,10);   a_ss13 = diag_3d(:,:,17)
      a_ss04 = diag_3d(:,:,4);   a_ss09 = diag_3d(:,:,11);   a_ss14 = diag_3d(:,:,18)
      a_ss05 = diag_3d(:,:,5);   a_ss10 = diag_3d(:,:,12);   a_ss15 = diag_3d(:,:,19)
      a_ss06 = diag_3d(:,:,6);   a_ss10 = diag_3d(:,:,13);   a_ss15 = diag_3d(:,:,20)
      a_ss07 = diag_3d(:,:,7);   a_ss10 = diag_3d(:,:,14)

   case('MP_P3')

      !#  Predicted Particle Properties (P3) microphysics (v2.9.1)
      if (p3_ncat == 1) then

         istat1 = mp_p3_wrapper_gem(qqm,qqp,ttm,ttp,dt,p3_dtmax,ww,psp,zgztherm,sigma,   &
                  kount,trnch,ni,nk,a_tls,a_tss,a_tls_rn1,a_tls_rn2,a_tss_sn1,           &
                  a_tss_sn2,a_tss_sn3,a_tss_pe1,a_tss_pe2,a_tss_snd,                     &
                  a_zet,a_zec,a_effradc,qcp,ncp,qrp,nrp,p3_ncat,                         &
                  n_diag_2d,diag_2d,n_diag_3d,diag_3d,qi_type,a_fxp,                     &
                  p3_depfact,p3_subfact,p3_debug,                                        &
                  qti1p,qmi1p,nti1p,bmi1p,a_effradi1)
         if (istat1 >= 0) then
            iwc_total = qti1p
            where (qti1p(:,1:nk)<1.e-14) a_effradi1 = 0.
         endif

      elseif (p3_ncat == 2) then

         istat1 = mp_p3_wrapper_gem(qqm,qqp,ttm,ttp,dt,p3_dtmax,ww,psp,zgztherm,sigma,   &
                  kount,trnch,ni,nk,a_tls,a_tss,a_tls_rn1,a_tls_rn2,a_tss_sn1,           &
                  a_tss_sn2,a_tss_sn3,a_tss_pe1,a_tss_pe2,a_tss_snd,                     &
                  a_zet,a_zec,a_effradc,qcp,ncp,qrp,nrp,p3_ncat,                         &
                  n_diag_2d,diag_2d,n_diag_3d,diag_3d,qi_type,a_fxp,                     &
                  p3_depfact,p3_subfact,p3_debug,                                        &
                  qti1p,qmi1p,nti1p,bmi1p,a_effradi1,                                    &
                  qti2p,qmi2p,nti2p,bmi2p,a_effradi2)
         if (istat1 >= 0) then
            iwc_total = qti1p + qti2p
            where (qti1p(:,1:nk)<1.e-14) a_effradi1 = 0.
            where (qti2p(:,1:nk)<1.e-14) a_effradi2 = 0.
         endif

      elseif (p3_ncat == 3) then

         istat1 = mp_p3_wrapper_gem(qqm,qqp,ttm,ttp,dt,p3_dtmax,ww,psp,zgztherm,sigma,   &
                  kount,trnch,ni,nk,a_tls,a_tss,a_tls_rn1,a_tls_rn2,a_tss_sn1,           &
                  a_tss_sn2,a_tss_sn3,a_tss_pe1,a_tss_pe2,a_tss_snd,                     &
                  a_zet,a_zec,a_effradc,qcp,ncp,qrp,nrp,p3_ncat,                         &
                  n_diag_2d,diag_2d,n_diag_3d,diag_3d,qi_type,a_fxp,                     &
                  p3_depfact,p3_subfact,p3_debug,                                        &
                  qti1p,qmi1p,nti1p,bmi1p,a_effradi1,                                    &
                  qti2p,qmi2p,nti2p,bmi2p,a_effradi2,                                    &
                  qti3p,qmi3p,nti3p,bmi3p,a_effradi3)
         if (istat1 >= 0) then
            iwc_total = qti1p + qti2p + qti3p
            where (qti1p(:,1:nk)<1.e-14) a_effradi1 = 0.
            where (qti2p(:,1:nk)<1.e-14) a_effradi2 = 0.
            where (qti3p(:,1:nk)<1.e-14) a_effradi3 = 0.
         endif

      elseif (p3_ncat == 4) then

         istat1 = mp_p3_wrapper_gem(qqm,qqp,ttm,ttp,dt,p3_dtmax,ww,psp,zgztherm,sigma,   &
                  kount,trnch,ni,nk,a_tls,a_tss,a_tls_rn1,a_tls_rn2,a_tss_sn1,           &
                  a_tss_sn2,a_tss_sn3,a_tss_pe1,a_tss_pe2,a_tss_snd,                     &
                  a_zet,a_zec,a_effradc,qcp,ncp,qrp,nrp,p3_ncat,                         &
                  n_diag_2d,diag_2d,n_diag_3d,diag_3d,qi_type,a_fxp,                     &
                  p3_depfact,p3_subfact,p3_debug,                                        &
                  qti1p,qmi1p,nti1p,bmi1p,a_effradi1,                                    &
                  qti2p,qmi2p,nti2p,bmi2p,a_effradi2,                                    &
                  qti3p,qmi3p,nti3p,bmi3p,a_effradi3,                                    &
                  qti4p,qmi4p,nti4p,bmi4p,a_effradi4)
         if (istat1 >= 0) then
            iwc_total = qti1p + qti2p + qti3p + qti4p
            where (qti1p(:,1:nk)<1.e-14) a_effradi1 = 0.
            where (qti2p(:,1:nk)<1.e-14) a_effradi2 = 0.
            where (qti3p(:,1:nk)<1.e-14) a_effradi3 = 0.
            where (qti4p(:,1:nk)<1.e-14) a_effradi4 = 0.
         endif

      endif

      if (istat1 < 0) then
         print*, 'ERROR (condensation) Problem in P3'
         stop
      endif

     !temporary; rn/fr (rate) partition should be done in s/r 'calcdiag'
     !(but currently it is still done inside microphyics scheme for MY2)
      a_tls_fr1 = 0.
      a_tls_fr2 = 0.

     !diagnostic ice particle types:
      a_qi_1 = qi_type(:,:,1)  !small ice crystals
      a_qi_2 = qi_type(:,:,2)  !unrimed snow crystals
      a_qi_3 = qi_type(:,:,3)  !lightly rimed snow
      a_qi_4 = qi_type(:,:,4)  !graupel
      a_qi_5 = qi_type(:,:,5)  !hail
      a_qi_6 = qi_type(:,:,6)  !ice pellets


      if (.true.) then  ! namelist switch to be added
         a_d2d01 = diag_2d(:,1);    a_d2d08 = diag_2d(:, 8);    a_d2d15 = diag_2d(:,15)
         a_d2d02 = diag_2d(:,2);    a_d2d09 = diag_2d(:, 9);    a_d2d16 = diag_2d(:,16)
         a_d2d03 = diag_2d(:,3);    a_d2d10 = diag_2d(:,10);    a_d2d17 = diag_2d(:,17)
         a_d2d14 = diag_2d(:,4);    a_d2d11 = diag_2d(:,11);    a_d2d18 = diag_2d(:,18)
         a_d2d15 = diag_2d(:,5);    a_d2d12 = diag_2d(:,12);    a_d2d19 = diag_2d(:,19)
         a_d2d16 = diag_2d(:,6);    a_d2d13 = diag_2d(:,13);    a_d2d20 = diag_2d(:,20)
         a_d2d17 = diag_2d(:,7);    a_d2d14 = diag_2d(:,14)

         a_ss01 = diag_3d(:,:,1);   a_ss08 = diag_3d(:,:, 8);   a_ss15 = diag_3d(:,:,15)
         a_ss02 = diag_3d(:,:,2);   a_ss09 = diag_3d(:,:, 9);   a_ss16 = diag_3d(:,:,16)
         a_ss03 = diag_3d(:,:,3);   a_ss10 = diag_3d(:,:,10);   a_ss17 = diag_3d(:,:,17)
         a_ss04 = diag_3d(:,:,4);   a_ss11 = diag_3d(:,:,11);   a_ss18 = diag_3d(:,:,18)
         a_ss05 = diag_3d(:,:,5);   a_ss12 = diag_3d(:,:,12);   a_ss19 = diag_3d(:,:,19)
         a_ss06 = diag_3d(:,:,6);   a_ss13 = diag_3d(:,:,13);   a_ss20 = diag_3d(:,:,20)
         a_ss07 = diag_3d(:,:,7);   a_ss14 = diag_3d(:,:,14)
      endif

   end select

   !# application des tendances convectives de qc (pour consun)
   if (any(stcond == (/'CONSUN','KUOSTD'/))) then
      qcp = qcp+tdmask2d*zcqce
   endif

   !# application des tendances stratiformes
   ttp = ttp + tdmask2d*zste
   qqp = qqp + tdmask2d*zsqe
   qcp = qcp + tdmask2d*zsqce

   if (stcond == 'MP_MY2_OLD') then
      qrp = max(0.,qrp + tdmask2d*zsqre )
      qip = max(0.,qip + tdmask2d*qitend)
      qgp = max(0.,qgp + tdmask2d*qgtend)
      qnp = max(0.,qnp + tdmask2d*qntend)
      qhp = max(0.,qhp + tdmask2d*qhtend)
      ncp = max(0.,ncp + tdmask2d*nctend)
      nrp = max(0.,nrp + tdmask2d*nrtend)
      nip = max(0.,nip + tdmask2d*nitend)
      ngp = max(0.,ngp + tdmask2d*ngtend)
      nnp = max(0.,nnp + tdmask2d*nntend)
      nhp = max(0.,nhp + tdmask2d*nhtend)
   endif

   if (stcond(1:6) == 'MP_MY2') then
      lqrp = qrp
      lqip = qip
      lqgp = qgp
      lqnp = qnp
   elseif (stcond == 'MP_P3') then
      lqrp = qrp
      lqip = iwc_total
      lqgp = 0.
      lqnp = 0.
   else
      lqrp = 0.
      lqip = 0.
      lqgp = 0.
      lqnp = 0.
   endif

   ! Local copies of the MY2 masses are used to avoid passing a nullified
   ! pointer through the interface.
   call water_integrated(f,fsiz,v,vsiz,ttp,qqp,qcp,lqip,lqrp,lqgp,lqnp,sigma,psp,ni,nk)

   !# en mode climat ou stratos, il n'y a pas de processus de
   !# convection/condensation au-dessus de topc ou bien si
   !# humoins est plus petit que minq
   if (climat .or. stratos) then
      press(:,:) = spread(psm(:), dim=2, ncopies=nk)
      press(:,:) = sigma(:,1:nk)*press(:,:)
      where(press < topc .or. qqm <= minq)
         zcte = 0.0
         zste = 0.0
         zcqe = 0.0
         zsqe = 0.0
         zcqce= 0.0
         zsqce= 0.0
         zcqre= 0.0
         zsqre= 0.0
      endwhere
      if (associated(zprcten)) then
         where(press < topc .or. qqm <= minq)
            zprcten= 0.0
         endwhere
      endif
   endif

   ztqcx = zsqce
   zqtde = zcqce*tdmask2d

!PV - use qctend to store total conv tend or only liquid tendency when MY is used
   if (lkfbe.and.stcond(1:3)=='MP_') then
     qctend=zprcten
   else
     qctend=zcqce
   endif

   if (.not.any(stcond == (/'MP_MY2','MP_P3 '/))) then
     do k=1,nk
      do i=1,ni
         ttp(i,k) =  t0(i,k)
         qqp(i,k) =  q0(i,k)
         qcp(i,k) = qc0(i,k)
      end do
     end do
   endif

   !# sommer les tendances convectives et stratiformes
   do k=1,nk
      do i=1,ni
         ttend(i,k)  = zcte(i,k)   + zste(i,k)
         qtend(i,k)  = zcqe(i,k)   + zsqe(i,k)
         qctend(i,k) = qctend(i,k) + zsqce(i,k)
         qrtend(i,k) = zcqre(i,k)  + zsqre(i,k)
         !# sortie des tendances
         zcte_(i,k) = zcte(i,k)
         zcqe_(i,k) = zcqe(i,k)
         zste_(i,k) = zste(i,k)
         zsqe_(i,k) = zsqe(i,k)
      end do
   end do

   !# tendances moyennees
   if ((moyhr > 0 .or. dynout) .and. kount > 0) then
      do k=1,nk
         do i=1,ni
            zzctem(i,k)  = zzctem(i,k)  + zcte(i,k)
            zzstem(i,k)  = zzstem(i,k)  + zste(i,k)
            zzcqem(i,k)  = zzcqem(i,k)  + zcqe(i,k)
            zzsqem(i,k)  = zzsqem(i,k)  + zsqe(i,k)
            zzcqcem(i,k) = zzcqcem(i,k) + zcqce(i,k)
            zzsqcem(i,k) = zzsqcem(i,k) + zsqce(i,k)
         end do
      end do
   endif

   call ccdiagnostics(f,fsiz,v,vsiz, zcte,zcqe,psp, &
        trnch,ni,nk,icpu,kount)

   if (conv_shal == 'BECHTOLD') then
      call apply_tendencies1(d,dsiz,v,vsiz,f,fsiz,tplus,tshal,ni,nk)
      call apply_tendencies1(d,dsiz,v,vsiz,f,fsiz,huplus,hushal,ni,nk)
   endif

   if (.not.any(stcond == (/'MP_MY2','MP_P3 '/))) then
      call apply_tendencies1(d,dsiz,v,vsiz,f,fsiz,tplus,tcond,ni,nk)
      call apply_tendencies1(d,dsiz,v,vsiz,f,fsiz,huplus,hucond,ni,nk)
      call apply_tendencies1(d,dsiz,v,vsiz,f,fsiz,qcplus,qcphytd,ni,nk)
   endif

   !# add shallow convection tendencies to convection/condensation tendencies
   do k=1,nk
      do i=1,ni
         qtend(i,k) = qtend(i,k) + zhushal(i,k)
         ttend(i,k) = ttend(i,k) + ztshal(i,k)
      end do
   end do

   if (stcond == 'MP_MY2_OLD') qcp = max(qcp, 0.)

   return
end subroutine condensation
