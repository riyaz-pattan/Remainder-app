import 'package:flutter/material.dart';

class CustomToast {
  static void show(BuildContext context, String message, {bool isError = false}) {
    final snackBar = SnackBar(
      content: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isError 
              ? Colors.redAccent.withOpacity(0.9) 
              : const Color(0xFF0066CC).withOpacity(0.9),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.2)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.water_drop, 
              color: Colors.white
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message, 
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      ),
      backgroundColor: Colors.transparent,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(bottom: 40, left: 20, right: 20),
      duration: const Duration(seconds: 3),
    );
    
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(snackBar);
  }
}
